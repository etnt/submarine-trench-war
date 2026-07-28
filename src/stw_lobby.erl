%%%-------------------------------------------------------------------
%% @doc Lobby / matchmaking registry.
%%
%% A single registered gen_server that:
%%   * mints player identities (player_id + session_token) on `hello`,
%%   * creates game rooms (spawning stw_game processes) and tracks
%%     room_code -> game pid,
%%   * resolves a session token back to its current room for reconnect.
%%
%% The lobby holds only lightweight routing/identity data. Authoritative
%% match state lives in the per-room stw_game process.
%% @end
%%%-------------------------------------------------------------------
-module(stw_lobby).

-behaviour(gen_server).

-export([start_link/0]).
-export([hello/2, create_game/2, join_room/2, lookup_room/1]).
-export([stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
-define(CODE_ALPHABET, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789").
-define(CODE_LEN, 6).

-record(state, {
    rooms = #{} :: #{binary() => pid()},
    room_mons = #{} :: #{reference() => binary()},
    sessions = #{} :: #{binary() => map()}
}).

%% --- API --------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Mint or resume a player identity. Returns the player id, the
%% session token to persist, and the room the session is currently in
%% (or `undefined`). Pass `undefined` as Token for a brand new player.
-spec hello(binary() | undefined, binary()) ->
    {binary(), binary(), binary() | undefined}.
hello(Token, DisplayName) ->
    gen_server:call(?SERVER, {hello, Token, DisplayName}).

%% @doc Create a new room, spawn its game process, and associate the
%% caller's session with it.
-spec create_game(binary(), map()) -> {ok, binary(), pid()}.
create_game(Token, Opts) ->
    gen_server:call(?SERVER, {create_game, Token, Opts}).

%% @doc Associate a session with an existing room by code.
-spec join_room(binary(), binary()) ->
    {ok, pid()} | {error, room_not_found}.
join_room(Token, RoomCode) ->
    gen_server:call(?SERVER, {join_room, Token, RoomCode}).

%% @doc Resolve a room code to its game process pid.
-spec lookup_room(binary()) -> {ok, pid()} | error.
lookup_room(RoomCode) ->
    gen_server:call(?SERVER, {lookup_room, RoomCode}).

%% @doc Lightweight observability snapshot for the /metrics endpoint.
%% Reports live rooms, tracked sessions, and how many sessions are
%% currently attached to a live room. Cheap (no per-game calls).
-spec stats() -> #{binary() => non_neg_integer()}.
stats() ->
    gen_server:call(?SERVER, stats).

%% --- gen_server -------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call({hello, Token, DisplayName}, _From, S) ->
    case find_session(Token, S) of
        {ok, Sess} ->
            RoomCode = live_room(maps:get(room_code, Sess, undefined), S),
            PlayerId = maps:get(player_id, Sess),
            Sess1 = Sess#{display_name => DisplayName, room_code => RoomCode},
            S1 = put_session(Token, Sess1, S),
            {reply, {PlayerId, Token, RoomCode}, S1};
        error ->
            PlayerId = new_player_id(),
            NewToken = new_token(),
            Sess = #{player_id => PlayerId,
                     display_name => DisplayName,
                     room_code => undefined},
            {reply, {PlayerId, NewToken, undefined},
             put_session(NewToken, Sess, S)}
    end;
handle_call({create_game, Token, Opts}, _From, S) ->
    RoomCode = unique_room_code(S#state.rooms),
    {ok, Pid} = stw_game_sup:start_game(RoomCode, Opts),
    Mon = erlang:monitor(process, Pid),
    S1 = S#state{rooms = maps:put(RoomCode, Pid, S#state.rooms),
                 room_mons = maps:put(Mon, RoomCode, S#state.room_mons),
                 sessions = set_session_room(Token, RoomCode, S#state.sessions)},
    {reply, {ok, RoomCode, Pid}, S1};
handle_call({join_room, Token, RoomCode}, _From, S) ->
    case maps:find(RoomCode, S#state.rooms) of
        {ok, Pid} ->
            S1 = S#state{sessions =
                             set_session_room(Token, RoomCode, S#state.sessions)},
            {reply, {ok, Pid}, S1};
        error ->
            {reply, {error, room_not_found}, S}
    end;
handle_call({lookup_room, RoomCode}, _From, S) ->
    {reply, maps:find(RoomCode, S#state.rooms), S};
handle_call(stats, _From, S) ->
    Rooms = S#state.rooms,
    InRoom = maps:fold(
               fun(_Token, Sess, Acc) ->
                   case maps:get(room_code, Sess, undefined) of
                       undefined -> Acc;
                       RC -> case maps:is_key(RC, Rooms) of
                                 true -> Acc + 1;
                                 false -> Acc
                             end
                   end
               end, 0, S#state.sessions),
    Stats = #{<<"active_games">> => maps:size(Rooms),
              <<"players_in_rooms">> => InRoom,
              <<"tracked_sessions">> => maps:size(S#state.sessions)},
    {reply, Stats, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, S) ->
    case maps:find(Mon, S#state.room_mons) of
        {ok, RoomCode} ->
            S1 = S#state{rooms = maps:remove(RoomCode, S#state.rooms),
                         room_mons = maps:remove(Mon, S#state.room_mons),
                         sessions = clear_room(RoomCode, S#state.sessions)},
            {noreply, S1};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% --- internal ---------------------------------------------------------

find_session(undefined, _S) -> error;
find_session(Token, S) -> maps:find(Token, S#state.sessions).

put_session(Token, Sess, S) ->
    S#state{sessions = maps:put(Token, Sess, S#state.sessions)}.

%% Return RoomCode only if that room still has a live game process.
live_room(undefined, _S) -> undefined;
live_room(RoomCode, S) ->
    case maps:is_key(RoomCode, S#state.rooms) of
        true -> RoomCode;
        false -> undefined
    end.

set_session_room(Token, RoomCode, Sessions) ->
    case maps:find(Token, Sessions) of
        {ok, Sess} -> maps:put(Token, Sess#{room_code => RoomCode}, Sessions);
        error -> Sessions
    end.

clear_room(RoomCode, Sessions) ->
    maps:map(
      fun(_Token, Sess) ->
          case maps:get(room_code, Sess, undefined) of
              RoomCode -> Sess#{room_code => undefined};
              _ -> Sess
          end
      end, Sessions).

new_player_id() ->
    <<"p_", (hex(4))/binary>>.

new_token() ->
    base64url(18).

hex(NBytes) ->
    Bin = crypto:strong_rand_bytes(NBytes),
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

base64url(NBytes) ->
    Bin = crypto:strong_rand_bytes(NBytes),
    B64 = base64:encode(Bin),
    << <<(url_char(C))>> || <<C>> <= B64, C =/= $= >>.

url_char($+) -> $-;
url_char($/) -> $_;
url_char(C) -> C.

unique_room_code(Rooms) ->
    Code = random_code(),
    case maps:is_key(Code, Rooms) of
        true -> unique_room_code(Rooms);
        false -> Code
    end.

random_code() ->
    Alphabet = ?CODE_ALPHABET,
    N = length(Alphabet),
    list_to_binary(
      [lists:nth(rand:uniform(N), Alphabet) || _ <- lists:seq(1, ?CODE_LEN)]).
