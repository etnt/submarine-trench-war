%%%-------------------------------------------------------------------
%% @doc Per-match game session process.
%%
%% Holds the authoritative membership and readiness state for one room.
%% Players are keyed by player_id and survive WebSocket disconnects: the
%% process monitors each connection's pid and, when it goes down, marks
%% the player disconnected but keeps them in the room so they can resume
%% via `reconnect/3`.
%%
%% Server->client messages are delivered by sending `{push, Type, Payload}`
%% to each connection pid; the WebSocket handler stamps the envelope and
%% forwards it. Phase 1 handles the lobby lifecycle; Phase 2 adds the board
%% and submarine state, carried by `game_started` when the match begins.
%% @end
%%%-------------------------------------------------------------------
-module(stw_game).

-behaviour(gen_server).

-export([start_link/2]).
-export([join/4, reconnect/3, leave/2, set_ready/3, start_game/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(COLORS, [<<"#3cf">>, <<"#f83">>, <<"#6c6">>, <<"#c6f">>]).
-define(START_HULL, 10).

-record(state, {
    room_code :: binary(),
    map_id :: binary(),
    max_players :: pos_integer(),
    host_id :: binary() | undefined,
    phase = lobby :: lobby | playing,
    join_order = [] :: [binary()],
    players = #{} :: #{binary() => map()},
    board :: stw_board:board(),
    subs = #{} :: #{binary() => map()}
}).

%% --- API --------------------------------------------------------------

start_link(RoomCode, Opts) ->
    gen_server:start_link(?MODULE, {RoomCode, Opts}, []).

%% @doc Add a player to the room, binding it to WsPid. Returns whether the
%% player is the host. If the player already exists this behaves like a
%% reconnect.
-spec join(pid(), binary(), binary(), pid()) ->
    {ok, boolean()} | {error, room_full}.
join(GamePid, PlayerId, DisplayName, WsPid) ->
    gen_server:call(GamePid, {join, PlayerId, DisplayName, WsPid}).

%% @doc Re-bind an existing player to a new WsPid after reconnecting.
-spec reconnect(pid(), binary(), pid()) -> ok | {error, not_in_room}.
reconnect(GamePid, PlayerId, WsPid) ->
    gen_server:call(GamePid, {reconnect, PlayerId, WsPid}).

-spec leave(pid(), binary()) -> ok.
leave(GamePid, PlayerId) ->
    gen_server:cast(GamePid, {leave, PlayerId}).

-spec set_ready(pid(), binary(), boolean()) -> ok | {error, not_in_room}.
set_ready(GamePid, PlayerId, Ready) ->
    gen_server:call(GamePid, {set_ready, PlayerId, Ready}).

-spec start_game(pid(), binary()) -> ok | {error, not_host}.
start_game(GamePid, PlayerId) ->
    gen_server:call(GamePid, {start_game, PlayerId}).

%% --- gen_server -------------------------------------------------------

init({RoomCode, Opts}) ->
    {ok, #state{room_code = RoomCode,
                map_id = opt(map_id, Opts, <<"trench_alpha">>),
                max_players = opt(max_players, Opts, 4),
                board = stw_board:default()}}.

handle_call({join, PlayerId, DisplayName, WsPid}, _From, S) ->
    case maps:is_key(PlayerId, S#state.players) of
        true ->
            S1 = attach_ws(PlayerId, WsPid, S),
            broadcast_lobby(S1),
            {reply, {ok, S1#state.host_id =:= PlayerId}, S1};
        false ->
            case map_size(S#state.players) >= S#state.max_players of
                true ->
                    {reply, {error, room_full}, S};
                false ->
                    S1 = add_player(PlayerId, DisplayName, WsPid, S),
                    broadcast_lobby(S1),
                    {reply, {ok, S1#state.host_id =:= PlayerId}, S1}
            end
    end;
handle_call({reconnect, PlayerId, WsPid}, _From, S) ->
    case maps:is_key(PlayerId, S#state.players) of
        true ->
            S1 = attach_ws(PlayerId, WsPid, S),
            case S1#state.phase of
                playing ->
                    push(WsPid, <<"game_started">>, game_started_payload(S1));
                lobby ->
                    ok
            end,
            push(WsPid, <<"lobby_state">>, lobby_payload(S1)),
            broadcast_lobby(S1),
            {reply, ok, S1};
        false ->
            {reply, {error, not_in_room}, S}
    end;
handle_call({set_ready, PlayerId, Ready}, _From, S) ->
    case maps:find(PlayerId, S#state.players) of
        {ok, P} ->
            S1 = put_player(PlayerId, P#{ready => Ready}, S),
            broadcast_lobby(S1),
            {reply, ok, S1};
        error ->
            {reply, {error, not_in_room}, S}
    end;
handle_call({start_game, PlayerId}, _From, S) ->
    case PlayerId =:= S#state.host_id of
        true ->
            S1 = S#state{phase = playing, subs = place_subs(S)},
            broadcast(S1, <<"game_started">>, game_started_payload(S1)),
            {reply, ok, S1};
        false ->
            {reply, {error, not_host}, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast({leave, PlayerId}, S) ->
    S1 = remove_player(PlayerId, S),
    case map_size(S1#state.players) of
        0 ->
            {stop, normal, S1};
        _ ->
            broadcast_lobby(S1),
            {noreply, S1}
    end;
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, S) ->
    case find_by_mon(Mon, S) of
        {ok, PlayerId, P} ->
            P1 = P#{connected => false, ws_pid => undefined, mon => undefined},
            S1 = put_player(PlayerId, P1, S),
            broadcast_lobby(S1),
            {noreply, S1};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% --- player helpers ---------------------------------------------------

add_player(PlayerId, DisplayName, WsPid, S) ->
    Mon = erlang:monitor(process, WsPid),
    Player = #{display_name => DisplayName,
               ready => false,
               ws_pid => WsPid,
               mon => Mon,
               connected => true},
    Host = case S#state.host_id of
               undefined -> PlayerId;
               H -> H
           end,
    S#state{players = maps:put(PlayerId, Player, S#state.players),
            join_order = S#state.join_order ++ [PlayerId],
            host_id = Host}.

%% Bind (or re-bind) a player's connection pid, replacing any old monitor.
attach_ws(PlayerId, WsPid, S) ->
    P0 = maps:get(PlayerId, S#state.players),
    demonitor_player(P0),
    Mon = erlang:monitor(process, WsPid),
    P1 = P0#{ws_pid => WsPid, mon => Mon, connected => true},
    put_player(PlayerId, P1, S).

remove_player(PlayerId, S) ->
    case maps:find(PlayerId, S#state.players) of
        {ok, P} ->
            demonitor_player(P),
            Players = maps:remove(PlayerId, S#state.players),
            Order = lists:delete(PlayerId, S#state.join_order),
            HostId = reassign_host(PlayerId, S#state.host_id, Order),
            S#state{players = Players, join_order = Order, host_id = HostId};
        error ->
            S
    end.

reassign_host(PlayerId, PlayerId, []) -> undefined;
reassign_host(PlayerId, PlayerId, [Next | _]) -> Next;
reassign_host(_Left, CurrentHost, _Order) -> CurrentHost.

demonitor_player(#{mon := Mon}) when is_reference(Mon) ->
    erlang:demonitor(Mon, [flush]),
    ok;
demonitor_player(_) ->
    ok.

put_player(PlayerId, P, S) ->
    S#state{players = maps:put(PlayerId, P, S#state.players)}.

find_by_mon(Mon, S) ->
    Found = maps:fold(
              fun(_Id, _P, {ok, _, _} = Acc) -> Acc;
                 (Id, #{mon := M} = P, error) when M =:= Mon -> {ok, Id, P};
                 (_Id, _P, Acc) -> Acc
              end, error, S#state.players),
    Found.

%% --- messaging --------------------------------------------------------

push(undefined, _Type, _Payload) -> ok;
push(WsPid, Type, Payload) when is_pid(WsPid) ->
    WsPid ! {push, Type, Payload},
    ok.

broadcast_lobby(S) ->
    broadcast(S, <<"lobby_state">>, lobby_payload(S)).

broadcast(S, Type, Payload) ->
    lists:foreach(
      fun(Id) ->
          case maps:find(Id, S#state.players) of
              {ok, #{ws_pid := WsPid}} -> push(WsPid, Type, Payload);
              _ -> ok
          end
      end, S#state.join_order).

lobby_payload(S) ->
    #{<<"room_code">> => S#state.room_code,
      <<"map_id">> => S#state.map_id,
      <<"host_id">> => nullify(S#state.host_id),
      <<"phase">> => atom_to_binary(S#state.phase),
      <<"players">> => [player_json(Id, maps:get(Id, S#state.players))
                        || Id <- S#state.join_order]}.

player_json(Id, P) ->
    #{<<"player_id">> => Id,
      <<"display_name">> => maps:get(display_name, P),
      <<"ready">> => maps:get(ready, P),
      <<"connected">> => maps:get(connected, P)}.

game_started_payload(S) ->
    #{<<"map_id">> => S#state.map_id,
      <<"room_code">> => S#state.room_code,
      <<"board">> => stw_board:to_json(S#state.board),
      <<"submarines">> => submarines_json(S)}.

submarines_json(S) ->
    [sub_json(Idx, Id, S)
     || {Idx, Id} <- enumerate(S#state.join_order),
        maps:is_key(Id, S#state.subs)].

sub_json(Idx, Id, S) ->
    Sub = maps:get(Id, S#state.subs),
    P = maps:get(Id, S#state.players),
    #{<<"player_id">> => Id,
      <<"display_name">> => maps:get(display_name, P),
      <<"color">> => color_for(Idx),
      <<"x">> => maps:get(x, Sub),
      <<"y">> => maps:get(y, Sub),
      <<"facing">> => maps:get(facing, Sub),
      <<"depth">> => maps:get(depth, Sub),
      <<"hull">> => maps:get(hull, Sub),
      <<"data_collected">> => maps:get(data, Sub)}.

%% --- board / submarines ----------------------------------------------

%% Seat each player (in join order) on a spawn tile. Extra spawns are left
%% empty; there are never more players than spawns because max_players is
%% capped at the spawn count.
place_subs(S) ->
    Ids = S#state.join_order,
    Spawns = stw_board:spawns(S#state.board),
    {_, H} = stw_board:dims(S#state.board),
    N = min(length(Ids), length(Spawns)),
    Pairs = lists:zip(lists:sublist(Ids, N), lists:sublist(Spawns, N)),
    maps:from_list([{Id, make_sub(Spawn, H)} || {Id, Spawn} <- Pairs]).

make_sub({X, Y}, Height) ->
    #{x => X,
      y => Y,
      facing => facing_from(Y, Height),
      depth => <<"shallow">>,
      hull => ?START_HULL,
      data => 0}.

%% Point the sub toward the centre of the map from its spawn corner.
facing_from(Y, Height) when Y * 2 < Height -> <<"S">>;
facing_from(_Y, _Height) -> <<"N">>.

%% --- misc -------------------------------------------------------------

color_for(Idx) ->
    lists:nth((Idx rem length(?COLORS)) + 1, ?COLORS).

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

nullify(undefined) -> null;
nullify(V) -> V.

opt(Key, Opts, Default) ->
    maps:get(Key, Opts, Default).
