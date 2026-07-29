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
-export([program_registers/3, lock_registers/2, set_sonar_mode/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-ifdef(TEST).
%% Pure objective helpers exposed for unit testing.
-export([resolve_data/3, extraction_path/1]).
%% Dealing helper exposed so tests can verify the guaranteed Ahead card.
-export([ensure_ahead/1]).
%% Config helpers exposed so tests can verify env overrides.
-export([base_hand/0, min_hand/0, win_data/0, ping_timer_ms/0,
         collapse_interval/0]).
-endif.

%% Colourblind-safe fleet palette (Okabe-Ito derived): sky blue, orange,
%% bluish-green, reddish-purple. Chosen to stay distinguishable under the
%% common deutan/protan/tritan confusions; sub shape + name labels add a
%% second, non-colour channel on top.
-define(COLORS, [<<"#4eb3f5">>, <<"#e69f00">>, <<"#12b886">>, <<"#cc79a7">>]).
-define(START_HULL, 10).
-define(REGISTERS, 5).
-define(BASE_HAND, 9).
-define(MIN_HAND, 5).
-define(PING_TIMER_MS, 30000).
%% Data nodes a submarine must carry before it can extract and win.
-define(WIN_DATA, 3).
%% Dynamic map: every Nth round a trench section caves in (keeps matches
%% moving and discourages camping). COLLAPSE_TILES sections cave per event.
-define(COLLAPSE_INTERVAL, 3).
-define(COLLAPSE_TILES, 1).

-record(state, {
    room_code :: binary(),
    map_id :: binary(),
    max_players :: pos_integer(),
    host_id :: binary() | undefined,
    phase = lobby :: lobby | playing | finished,
    join_order = [] :: [binary()],
    players = #{} :: #{binary() => map()},
    board :: stw_board:board(),
    subs = #{} :: #{binary() => map()},
    round = 0 :: non_neg_integer(),
    hands = #{} :: #{binary() => [map()]},
    programs = #{} :: #{binary() => [binary()]},
    submitted = #{} :: #{binary() => [binary()]},
    locked = [] :: [binary()],
    sonar = #{} :: #{binary() => active | passive},
    ink = #{} :: #{stw_board:coord() => pos_integer()},
    decoys = [] :: [{binary(), stw_board:coord()}],
    nodes = [] :: [stw_board:coord()],
    extraction :: stw_board:coord() | undefined,
    epath = [] :: [stw_board:coord()],
    eidx = 0 :: non_neg_integer(),
    revealed = [] :: [binary()],
    winner = undefined :: binary() | undefined,
    finish_reason = undefined :: binary() | undefined,
    runner_up = undefined :: binary() | undefined,
    timer_ref :: reference() | undefined,
    timer_ends :: integer() | undefined
}).

%% --- Tunables ---------------------------------------------------------
%% Gameplay knobs are read from the `stw` application environment at use
%% time, each falling back to the compiled-in default. This lets playtests
%% iterate on balance via config/sys.config (or `application:set_env/3`)
%% without recompiling. See config/sys.config for the documented keys.

-spec base_hand() -> pos_integer().
base_hand() -> application:get_env(stw, base_hand, ?BASE_HAND).

-spec min_hand() -> pos_integer().
min_hand() -> application:get_env(stw, min_hand, ?MIN_HAND).

-spec win_data() -> pos_integer().
win_data() -> application:get_env(stw, win_data, ?WIN_DATA).

-spec ping_timer_ms() -> pos_integer().
ping_timer_ms() -> application:get_env(stw, ping_timer_ms, ?PING_TIMER_MS).

-spec collapse_interval() -> pos_integer().
collapse_interval() -> application:get_env(stw, collapse_interval, ?COLLAPSE_INTERVAL).

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

%% @doc Submit an ordered list of 5 card IDs (drawn from this round's dealt
%% hand) to program into the registers.
-spec program_registers(pid(), binary(), [binary()]) ->
    ok | {error, atom()}.
program_registers(GamePid, PlayerId, Cards) ->
    gen_server:call(GamePid, {program, PlayerId, Cards}).

%% @doc Lock in the current program; when everyone has locked the round
%% resolves.
-spec lock_registers(pid(), binary()) -> ok | {error, atom()}.
lock_registers(GamePid, PlayerId) ->
    gen_server:call(GamePid, {lock, PlayerId}).

%% @doc Choose active or passive sonar for this player. Active sonar widens
%% vision but broadcasts the player's position to everyone.
-spec set_sonar_mode(pid(), binary(), binary() | atom()) -> ok.
set_sonar_mode(GamePid, PlayerId, Mode) ->
    gen_server:call(GamePid, {set_sonar_mode, PlayerId, Mode}).

%% --- gen_server -------------------------------------------------------

init({RoomCode, Opts}) ->
    MapId = opt(map_id, Opts, <<"trench_alpha">>),
    logger:info("stw game ~s created (map=~s)", [RoomCode, MapId]),
    {ok, #state{room_code = RoomCode,
                map_id = MapId,
                max_players = opt(max_players, Opts, 4),
                board = stw_board:by_id(MapId)}}.

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
                    push(WsPid, <<"game_started">>, game_started_payload(S1)),
                    push(WsPid, <<"game_state">>, player_view(S1, PlayerId)),
                    push(WsPid, <<"round_started">>, round_started_payload(S1)),
                    push_hand(S1, PlayerId),
                    maybe_restore_program(S1, PlayerId, WsPid),
                    maybe_push_timer(S1, WsPid);
                finished ->
                    push(WsPid, <<"game_started">>, game_started_payload(S1)),
                    push(WsPid, <<"game_state">>, player_view(S1, PlayerId)),
                    push(WsPid, <<"game_over">>,
                         game_over_payload(S1, S1#state.winner,
                                           S1#state.finish_reason,
                                           S1#state.runner_up));
                lobby ->
                    ok
            end,
            push(WsPid, <<"lobby_state">>, lobby_payload(S1)),
            broadcast_lobby(S1),
            {reply, ok, S1};
        false ->
            {reply, {error, not_in_room}, S}
    end;

handle_call({start_game, PlayerId}, _From, S) ->
    case PlayerId =:= S#state.host_id of
        true ->
            EPath = extraction_path(S#state.board),
            S1 = S#state{phase = playing, subs = place_subs(S),
                         round = 1, programs = #{}, locked = [],
                         submitted = #{}, ink = #{}, decoys = [],
                         nodes = stw_board:data_nodes(S#state.board),
                         epath = EPath, eidx = 0, extraction = hd(EPath),
                         revealed = [], winner = undefined,
                         finish_reason = undefined, runner_up = undefined,
                         timer_ref = undefined, timer_ends = undefined},
            logger:info("stw game ~s started with ~p players",
                        [S#state.room_code, map_size(S#state.players)]),
            broadcast(S1, <<"game_started">>, game_started_payload(S1)),
            S2 = deal_and_announce(S1),
            {reply, ok, S2};
        false ->
            {reply, {error, not_host}, S}
    end;
handle_call({program, PlayerId, Cards}, _From, S) ->
    case validate_program(PlayerId, Cards, S) of
        {ok, Kinds} ->
            S1 = S#state{programs = maps:put(PlayerId, Kinds, S#state.programs),
                         submitted = maps:put(PlayerId, Cards, S#state.submitted)},
            {reply, ok, S1};
        {error, _} = Err ->
            {reply, Err, S}
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
handle_call({set_sonar_mode, PlayerId, Mode}, _From, S) ->
    S1 = S#state{sonar = maps:put(PlayerId, parse_mode(Mode), S#state.sonar)},
    %% Reflect the change immediately: switching to active widens this
    %% player's view and reveals them to everyone, so refresh all snapshots.
    case S1#state.phase of
        playing -> broadcast_game_state(S1);
        _ -> ok
    end,
    {reply, ok, S1};
handle_call({lock, PlayerId}, _From, S) ->
    case S#state.phase =:= playing andalso maps:is_key(PlayerId, S#state.subs) of
        false ->
            {reply, {error, not_in_game}, S};
        true ->
            case maps:is_key(PlayerId, S#state.programs) of
                false ->
                    {reply, {error, no_program}, S};
                true ->
                    Locked = lists:usort([PlayerId | S#state.locked]),
                    S1 = maybe_start_timer(S#state{locked = Locked}),
                    broadcast(S1, <<"player_locked">>, locked_payload(S1, PlayerId)),
                    {reply, ok, maybe_resolve(S1)}
            end
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
handle_info(ping_timeout, S) ->
    Seated = maps:keys(S#state.subs),
    Unlocked = Seated -- S#state.locked,
    case S#state.phase =:= playing andalso Unlocked =/= [] of
        false ->
            {noreply, cancel_timer(S)};
        true ->
            {noreply, resolve_on_timeout(S, Unlocked)}
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

round_started_payload(S) ->
    #{<<"round">> => S#state.round,
      <<"registers">> => ?REGISTERS}.

deal_hand_payload(Round, PlayerId, Hand) ->
    #{<<"round">> => Round,
      <<"player_id">> => PlayerId,
      <<"cards">> => Hand}.

resolving_payload(S, AutoFilled) ->
    #{<<"round">> => S#state.round,
      <<"auto_filled">> => AutoFilled}.

timer_payload(S) ->
    #{<<"duration_ms">> => ping_timer_ms(),
      <<"ends_at">> => S#state.timer_ends}.

locked_payload(S, PlayerId) ->
    #{<<"player_id">> => PlayerId,
      <<"locked">> => length(S#state.locked),
      <<"total">> => length(seated_ids(S))}.

%% --- fog of war -------------------------------------------------------

%% Send every player (including spectators) their personalized fogged view.
broadcast_game_state(S) ->
    lists:foreach(
      fun(Id) -> push(ws_of(Id, S), <<"game_state">>, player_view(S, Id)) end,
      S#state.join_order).

%% A single player's authoritative snapshot, trimmed to what they can see.
%% Spectators (eliminated or not seated) get the full board.
player_view(S, PlayerId) ->
    Base = #{<<"round">> => S#state.round,
             <<"sonar_mode">> => atom_to_binary(sonar_mode(S, PlayerId)),
             <<"ink_clouds">> => ink_json(S),
             <<"decoys">> => decoys_for(S, PlayerId),
             <<"extraction">> => coord_json(S#state.extraction),
             <<"win_data">> => win_data()},
    case is_spectator(S, PlayerId) of
        true ->
            Base#{<<"spectator">> => true,
                  <<"you">> => null,
                  <<"submarines">> => submarines_json(S),
                  <<"visible_tiles">> => [],
                  <<"data_nodes">> => [coord_json(C) || C <- S#state.nodes],
                  <<"broadcasts">> => []};
        false ->
            VisIds = visible_ids(S, PlayerId),
            Tiles = visible_tiles(S, PlayerId),
            Base#{<<"spectator">> => false,
                  <<"you">> => sub_json(index_of(PlayerId, S), PlayerId, S),
                  <<"submarines">> => [sub_json(index_of(Id, S), Id, S)
                                       || Id <- VisIds],
                  <<"visible_tiles">> => [coord_json(C) || C <- Tiles],
                  <<"data_nodes">> => [coord_json(C)
                                       || C <- visible_nodes(S, PlayerId)],
                  <<"broadcasts">> => [Id || Id <- forced_ids(S),
                                             Id =/= PlayerId]}
    end.

%% Send every player their fogged replay of the round.
broadcast_round_result(S, Phases, MinesCleared) ->
    Ink = ink_tiles(S),
    Actives = forced_ids(S),
    Cleared = [coord_json(C) || C <- MinesCleared],
    lists:foreach(
      fun(Id) ->
          Payload = round_result_view(S, Id, Phases, Cleared, Ink, Actives),
          push(ws_of(Id, S), <<"round_result">>, Payload)
      end, S#state.join_order).

round_result_view(S, PlayerId, Phases, Cleared, Ink, Actives) ->
    Base = #{<<"round">> => S#state.round, <<"mines_cleared">> => Cleared},
    case is_spectator(S, PlayerId) of
        true ->
            Base#{<<"phases">> => Phases,
                  <<"submarines">> => submarines_json(S)};
        false ->
            Mode = sonar_mode(S, PlayerId),
            FoggedPhases = [fog_phase(S#state.board, Ph, PlayerId, Mode,
                                      Ink, Actives) || Ph <- Phases],
            VisIds = visible_ids(S, PlayerId),
            Base#{<<"phases">> => FoggedPhases,
                  <<"submarines">> => [sub_json(index_of(Id, S), Id, S)
                                       || Id <- VisIds]}
    end.

%% Trim a phase's submarine snapshot to the subs the viewer could see from
%% their own position in that phase. Combat FX events are left intact, but a
%% decoy launch is hidden from everyone except its owner so the false contact
%% it leaves next round is not given away during the replay.
fog_phase(Board, Phase, PlayerId, Mode, Ink, Actives) ->
    Snap = maps:get(<<"submarines">>, Phase),
    Phase1 = Phase#{<<"events">> => visible_events(Phase, PlayerId)},
    case lists:keyfind(PlayerId, 2, [{E, maps:get(<<"player_id">>, E)}
                                     || E <- Snap]) of
        false ->
            Phase1;
        _ ->
            Me = snap_entry(Snap, PlayerId),
            Visible = [E || E <- Snap,
                            snap_visible(Board, Me, Mode, Ink, Actives,
                                         PlayerId, E)],
            Phase1#{<<"submarines">> => Visible}
    end.

%% Drop decoy launch events owned by other players; keep everything else.
visible_events(Phase, PlayerId) ->
    [E || E <- maps:get(<<"events">>, Phase, []),
          maps:get(<<"type">>, E) =/= <<"decoy">>
              orelse maps:get(<<"player_id">>, E) =:= PlayerId].

snap_entry(Snap, PlayerId) ->
    hd([E || E <- Snap, maps:get(<<"player_id">>, E) =:= PlayerId]).

%% Whether the viewer (whose snapshot entry is Me) can see snapshot entry E.
snap_visible(Board, Me, Mode, Ink, Actives, PlayerId, E) ->
    Id = maps:get(<<"player_id">>, E),
    C = {maps:get(<<"x">>, E), maps:get(<<"y">>, E)},
    Id =:= PlayerId
        orelse lists:member(Id, Actives)
        orelse (not lists:member(C, Ink)
                andalso stw_vision:sees(Board, snap_sub(Me), Mode, C)).

%% A vision-ready sub map from a wire snapshot entry.
snap_sub(E) ->
    #{x => maps:get(<<"x">>, E),
      y => maps:get(<<"y">>, E),
      facing => maps:get(<<"facing">>, E),
      depth => maps:get(<<"depth">>, E)}.

%% Ids of submarines the viewer can currently see (own + active pingers +
%% anything within sonar range and not hidden by ink).
visible_ids(S, PlayerId) ->
    Me = maps:get(PlayerId, S#state.subs),
    Mode = sonar_mode(S, PlayerId),
    Ink = ink_tiles(S),
    Actives = forced_ids(S),
    [Id || Id <- S#state.join_order,
           maps:is_key(Id, S#state.subs),
           begin
               Sub = maps:get(Id, S#state.subs),
               C = {maps:get(x, Sub), maps:get(y, Sub)},
               Id =:= PlayerId
                   orelse lists:member(Id, Actives)
                   orelse (not lists:member(C, Ink)
                           andalso stw_vision:sees(S#state.board, Me, Mode, C))
           end].

visible_tiles(S, PlayerId) ->
    Me = maps:get(PlayerId, S#state.subs),
    stw_vision:visible_tiles(S#state.board, Me, sonar_mode(S, PlayerId)).

%% A player spectates when they hold no submarine or have been destroyed.
is_spectator(S, PlayerId) ->
    (not maps:is_key(PlayerId, S#state.subs)) orelse (not is_alive(PlayerId, S)).

sonar_mode(S, PlayerId) ->
    maps:get(PlayerId, S#state.sonar, passive).

%% Players actively pinging: their position is broadcast to everyone.
active_ids(S) ->
    [Id || Id <- seated_ids(S), sonar_mode(S, Id) =:= active].

%% Submarines forced visible to everyone this turn: active pingers plus any
%% extraction-ready leaders that were announced.
forced_ids(S) ->
    lists:usort(active_ids(S) ++ S#state.revealed).

%% Data nodes the player can currently see (within sonar range, not inked).
visible_nodes(S, PlayerId) ->
    case maps:find(PlayerId, S#state.subs) of
        {ok, Me} ->
            Mode = sonar_mode(S, PlayerId),
            Ink = ink_tiles(S),
            [C || C <- S#state.nodes,
                  not lists:member(C, Ink),
                  stw_vision:sees(S#state.board, Me, Mode, C)];
        error ->
            []
    end.

parse_mode(<<"active">>) -> active;
parse_mode(active) -> active;
parse_mode(_) -> passive.

%% --- ink clouds -------------------------------------------------------

ink_tiles(S) -> maps:keys(S#state.ink).

ink_json(S) -> [coord_json(C) || C <- ink_tiles(S)].

%% Decoy signatures shown on a player's scope. A player never sees their own
%% decoy (they know it is a bluff); everyone else gets the false contact.
decoys_for(S, PlayerId) ->
    [coord_json(C) || {Owner, C} <- S#state.decoys, Owner =/= PlayerId].

%% Age clouds by one round, dropping any that have expired.
tick_ink(Ink) ->
    maps:from_list([{C, T - 1} || {C, T} <- maps:to_list(Ink), T - 1 > 0]).

%% Freshly deployed clouds block visibility for two rounds.
add_ink(Ink, Coords) ->
    lists:foldl(fun(C, Acc) -> maps:put(C, 2, Acc) end, Ink, Coords).

coord_json({X, Y}) -> #{<<"x">> => X, <<"y">> => Y}.

%% --- round resolution -------------------------------------------------

%% Deal fresh hands, announce the round, and send each player their private
%% hand. Called at game start and after every resolution.
deal_and_announce(S) ->
    Hands = deal_hands(S),
    S1 = S#state{hands = Hands},
    broadcast(S1, <<"round_started">>, round_started_payload(S1)),
    lists:foreach(fun(Id) -> push_hand(S1, Id) end, seated_ids(S1)),
    broadcast_game_state(S1),
    S1.

%% Build a hand per seated player, sized by that sub's remaining hull.
deal_hands(S) ->
    Round = S#state.round,
    maps:from_list(
      [{Id, deal_one_hand(Round, hull_of(Id, S))} || Id <- seated_ids(S)]).

deal_one_hand(Round, Hull) ->
    N = hand_size(Hull),
    Hand = [#{<<"id">> => card_id(Round, I), <<"kind">> => random_kind()}
            || I <- lists:seq(1, N)],
    ensure_ahead(Hand).

%% Guarantee at least one forward-movement card in the hand: if the random
%% draw produced none, overwrite a random slot's kind with an Ahead card so
%% a player is never stranded without a way to advance. The card ids (and
%% thus hand size) are untouched.
ensure_ahead(Hand) ->
    Ahead = stw_engine:ahead_cards(),
    HasAhead = lists:any(fun(#{<<"kind">> := K}) -> lists:member(K, Ahead) end,
                         Hand),
    case HasAhead of
        true ->
            Hand;
        false ->
            Idx = rand:uniform(length(Hand)),
            Card = pick(Ahead),
            [case J =:= Idx of
                 true -> C#{<<"kind">> => Card};
                 false -> C
             end || {J, C} <- lists:zip(lists:seq(1, length(Hand)), Hand)]
    end.

%% Full hull => full hand; each point of damage removes one card, never
%% dropping below the register count (a damaged nav-computer offers less).
hand_size(Hull) ->
    max(min_hand(), base_hand() - (?START_HULL - Hull)).

card_id(Round, Idx) ->
    <<"r", (integer_to_binary(Round))/binary,
      "c", (integer_to_binary(Idx))/binary>>.

%% Weighted deck: roughly three navigation cards to each tactical card, so
%% players usually have the movement they need but combat still shows up.
random_kind() ->
    case rand:uniform(4) of
        1 -> pick(stw_engine:tactical_cards());
        _ -> pick(stw_engine:nav_cards())
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

push_hand(S, PlayerId) ->
    Hand = maps:get(PlayerId, S#state.hands, []),
    WsPid = ws_of(PlayerId, S),
    push(WsPid, <<"deal_hand">>,
         deal_hand_payload(S#state.round, PlayerId, Hand)).

%% After a mid-round reconnect, restore the player's own register slots and
%% locked status so the client UI matches the authoritative server state --
%% round_started on its own would leave the client looking freshly unlocked.
maybe_restore_program(S, PlayerId, WsPid) ->
    Submitted = maps:get(PlayerId, S#state.submitted, []),
    Locked = lists:member(PlayerId, S#state.locked),
    case Submitted =:= [] andalso not Locked of
        true ->
            ok;
        false ->
            push(WsPid, <<"program_restored">>,
                 #{<<"registers">> => Submitted,
                   <<"locked">> => Locked,
                   <<"locked_count">> => length(S#state.locked),
                   <<"total">> => length(seated_ids(S))})
    end.

%% Validate 5 distinct card IDs from the player's current hand and map them
%% to the ordered list of card kinds the engine consumes.
validate_program(PlayerId, Ids, S) ->
    IsPlaying = S#state.phase =:= playing,
    Seated = maps:is_key(PlayerId, S#state.subs),
    Hand = maps:get(PlayerId, S#state.hands, []),
    Distinct = length(lists:usort(Ids)) =:= length(Ids),
    TooMany = length(Ids) > ?REGISTERS,
    if
        not IsPlaying -> {error, not_in_game};
        not Seated -> {error, not_in_game};
        TooMany -> {error, invalid_register};
        not Distinct -> {error, invalid_register};
        true ->
            %% Fewer than 5 cards is allowed: any unfilled register defaults
            %% to a "hold" (do nothing), so a player short on useful cards can
            %% still lock in.
            case map_ids_to_kinds(Ids, Hand) of
                {ok, Kinds} ->
                    Pad = lists:duplicate(?REGISTERS - length(Kinds), <<"hold">>),
                    {ok, Kinds ++ Pad};
                Err -> Err
            end
    end.

map_ids_to_kinds(Ids, Hand) ->
    Index = maps:from_list([{maps:get(<<"id">>, C), maps:get(<<"kind">>, C)}
                            || C <- Hand]),
    case lists:all(fun(Id) -> maps:is_key(Id, Index) end, Ids) of
        true -> {ok, [maps:get(Id, Index) || Id <- Ids]};
        false -> {error, invalid_register}
    end.

%% Resolve the round once every seated player has locked in.
maybe_resolve(#state{phase = Phase} = S) when Phase =/= playing -> S;
maybe_resolve(S) ->
    Seated = lists:sort(seated_ids(S)),
    case Seated =/= [] andalso lists:sort(S#state.locked) =:= Seated of
        true -> resolve_round(S, []);
        false -> S
    end.

%% Ping Timer expired: auto-fill any unlocked players with random cards,
%% then resolve. Players who had programmed (but not locked) keep their
%% choice; only those with no program are flagged as auto-filled.
resolve_on_timeout(S, Unlocked) ->
    {Programs, AutoFilled} =
        lists:foldl(
          fun(Id, {Progs, Auto}) ->
              case maps:is_key(Id, Progs) of
                  true -> {Progs, Auto};
                  false ->
                      Kinds = [random_kind() || _ <- lists:seq(1, ?REGISTERS)],
                      {maps:put(Id, Kinds, Progs), [Id | Auto]}
              end
          end, {S#state.programs, []}, Unlocked),
    S1 = S#state{programs = Programs,
                 locked = lists:usort(S#state.locked ++ Unlocked)},
    resolve_round(S1, lists:reverse(AutoFilled)).

resolve_round(S, AutoFilled) ->
    S0 = cancel_timer(S),
    broadcast(S0, <<"registers_resolving">>, resolving_payload(S0, AutoFilled)),
    {Subs2, Phases, Effects} =
        stw_engine:resolve_round(S0#state.board, S0#state.subs, S0#state.programs),
    Cleared = maps:get(mines_cleared, Effects, []),
    NewInk = maps:get(ink_clouds, Effects, []),
    Decoys = maps:get(decoys, Effects, []),
    Board1 = lists:foldl(fun(C, B) -> stw_board:clear_mine(B, C) end,
                         S0#state.board, Cleared),
    %% Objective: download data nodes we ended the round on, then resolve data
    %% theft from any torpedo hits (a laden sub drops a recoverable node).
    {Subs3, Nodes1} = resolve_data(Subs2, S0#state.nodes, Phases),
    S1 = S0#state{subs = Subs3, board = Board1, nodes = Nodes1},
    %% Fog the replay per player using the ink clouds that were active during
    %% the round (before this round's fresh deploys take hold).
    broadcast_round_result(S1, Phases, Cleared),
    %% Sonar reveals: privately show each shooter the cards of anyone their
    %% ping connected with this round.
    reveal_sonar_hits(S0, Phases),
    %% Age existing ink clouds and add the ones deployed this round.
    Ink1 = add_ink(tick_ink(S1#state.ink), NewInk),
    %% Decide the match outcome from the freshly resolved positions.
    case match_result(S1) of
        {game_over, Winner, Reason, RunnerUp} ->
            end_match(S1#state{ink = Ink1}, Winner, Reason, RunnerUp);
        continue ->
            %% Reveal any extraction-ready leaders to everyone for one turn and
            %% advance the patrolling extraction zone before the next round.
            Leaders = extraction_leaders(S1),
            {Extraction1, Eidx1} = advance_extraction(S1),
            NextRound = S1#state.round + 1,
            %% Dynamic map: periodically cave in a trench section for the new
            %% round (never one that would trap a sub or split the board).
            {Board2, Collapsed} =
                maybe_collapse(S1#state{extraction = Extraction1}, NextRound),
            S2 = S1#state{round = NextRound,
                          board = Board2,
                          programs = #{}, locked = [], submitted = #{},
                          ink = Ink1, revealed = Leaders, decoys = Decoys,
                          extraction = Extraction1, eidx = Eidx1,
                          timer_ref = undefined, timer_ends = undefined},
            broadcast_collapse(S2, Collapsed),
            announce_leaders(S2, Leaders),
            deal_and_announce(S2)
    end.

%% --- Objective: data nodes, extraction, win conditions ----------------

%% Build the patrolling extraction ship's path: the open tiles along the top
%% interior row, ping-ponging so the zone sweeps back and forth.
extraction_path(Board) ->
    {W, _H} = stw_board:dims(Board),
    Fwd = [{X, 1} || X <- lists:seq(1, W - 2),
                     stw_board:tile_at(Board, {X, 1}) =/= wall],
    case Fwd of
        [] -> [stw_board:extraction(Board)];
        [_] -> Fwd;
        _ -> Fwd ++ lists:reverse(lists:droplast(tl(Fwd)))
    end.

%% Advance the extraction zone one step along its patrol path.
advance_extraction(#state{epath = []} = S) ->
    {S#state.extraction, 0};
advance_extraction(#state{epath = Path, eidx = Idx}) ->
    Idx1 = (Idx + 1) rem length(Path),
    {lists:nth(Idx1 + 1, Path), Idx1}.

%% --- Dynamic map: trench collapses ------------------------------------

%% Every ?COLLAPSE_INTERVAL rounds, cave in up to ?COLLAPSE_TILES trench
%% sections for the upcoming round. Returns the (possibly) mutated board and
%% the coords that collapsed (empty when it is not a collapse round or no safe
%% candidate exists).
maybe_collapse(S, Round) ->
    case Round rem collapse_interval() =:= 0 of
        false -> {S#state.board, []};
        true -> do_collapse(S, ?COLLAPSE_TILES, S#state.board, [])
    end.

do_collapse(_S, 0, Board, Acc) ->
    {Board, lists:reverse(Acc)};
do_collapse(S, N, Board, Acc) ->
    case collapse_candidates(S, Board) of
        [] ->
            {Board, lists:reverse(Acc)};
        Cands ->
            Coord = lists:nth(rand:uniform(length(Cands)), Cands),
            do_collapse(S, N - 1, stw_board:collapse(Board, Coord),
                        [Coord | Acc])
    end.

%% Plain trench tiles that are safe to wall: not occupied by a live sub, not an
%% objective (data node, extraction, or a tile on the extraction patrol), not a
%% feature (current/turbulence), and whose removal keeps the whole map
%% connected so nobody is ever trapped.
collapse_candidates(S, Board) ->
    Occupied = [{maps:get(x, Sub), maps:get(y, Sub)}
                || Sub <- maps:values(S#state.subs),
                   maps:get(alive, Sub, true)],
    Protected = sets:from_list(
                  Occupied ++ S#state.nodes ++ S#state.epath ++
                  [S#state.extraction]),
    [C || C <- stw_board:open_tiles(Board),
          stw_board:tile_at(Board, C) =:= trench,
          not sets:is_element(C, Protected),
          stw_board:current_at(Board, C) =:= none,
          not stw_board:turbulence_at(Board, C),
          stw_board:connected(stw_board:collapse(Board, C))].

broadcast_collapse(_S, []) ->
    ok;
broadcast_collapse(S, Collapsed) ->
    broadcast(S, <<"map_collapse">>,
              #{<<"round">> => S#state.round,
                <<"tiles">> => [coord_json(C) || C <- Collapsed]}).

%% Apply node downloads (a sub ending its round on a node collects it) and
%% data theft (a sub carrying data that took a torpedo hit drops one node on
%% its tile). Returns the updated submarines and remaining node coords.
resolve_data(Subs, Nodes, Phases) ->
    {Subs1, Nodes1} = collect_nodes(Subs, Nodes),
    drop_stolen(Subs1, Nodes1, torpedo_victims(Phases)).

collect_nodes(Subs, Nodes) ->
    lists:foldl(
      fun(Id, {Ss, Ns}) ->
          Sub = maps:get(Id, Ss),
          P = {maps:get(x, Sub), maps:get(y, Sub)},
          case maps:get(alive, Sub) andalso lists:member(P, Ns) of
              true ->
                  Sub1 = Sub#{data => maps:get(data, Sub) + 1},
                  {maps:put(Id, Sub1, Ss), lists:delete(P, Ns)};
              false ->
                  {Ss, Ns}
          end
      end, {Subs, Nodes}, lists:sort(maps:keys(Subs))).

drop_stolen(Subs, Nodes, Victims) ->
    lists:foldl(
      fun(Id, {Ss, Ns}) ->
          case maps:find(Id, Ss) of
              {ok, Sub} ->
                  case maps:get(alive, Sub) andalso maps:get(data, Sub) > 0 of
                      true ->
                          Sub1 = Sub#{data => maps:get(data, Sub) - 1},
                          P = {maps:get(x, Sub), maps:get(y, Sub)},
                          {maps:put(Id, Sub1, Ss), lists:usort([P | Ns])};
                      false ->
                          {Ss, Ns}
                  end;
              error ->
                  {Ss, Ns}
          end
      end, {Subs, Nodes}, lists:usort(Victims)).

%% The distinct submarines that took a torpedo hit this round.
torpedo_victims(Phases) ->
    [maps:get(<<"player_id">>, E)
     || Ph <- Phases, E <- maps:get(<<"events">>, Ph, []),
        maps:get(<<"type">>, E) =:= <<"hit">>,
        maps:get(<<"weapon">>, E, undefined) =:= <<"torpedo">>].

%% Determine whether the match has ended after a round.
match_result(S) ->
    case sort_by_priority(extractors(S), S) of
        [Winner | Rest] ->
            RunnerUp = case Rest of [R | _] -> R; [] -> undefined end,
            {game_over, Winner, <<"extracted">>, RunnerUp};
        [] ->
            Alive = alive_ids(S),
            case map_size(S#state.subs) >= 2 andalso length(Alive) =< 1 of
                true ->
                    Winner = case Alive of [W] -> W; [] -> undefined end,
                    Reason = case Winner of undefined -> <<"draw">>;
                                            _ -> <<"survivor">> end,
                    {game_over, Winner, Reason, undefined};
                false ->
                    continue
            end
    end.

%% Alive submarines sitting on the extraction zone at shallow depth with
%% enough data to win.
extractors(S) ->
    Ext = S#state.extraction,
    [Id || {Id, Sub} <- maps:to_list(S#state.subs),
           maps:get(alive, Sub),
           maps:get(depth, Sub) =:= <<"shallow">>,
           {maps:get(x, Sub), maps:get(y, Sub)} =:= Ext,
           maps:get(data, Sub) >= ?WIN_DATA].

%% Alive submarines carrying enough data to extract (revealed to all).
extraction_leaders(S) ->
    [Id || {Id, Sub} <- maps:to_list(S#state.subs),
           maps:get(alive, Sub),
           maps:get(data, Sub) >= ?WIN_DATA].

alive_ids(S) ->
    [Id || {Id, Sub} <- maps:to_list(S#state.subs), maps:get(alive, Sub)].

%% Order ids by most data first, breaking ties by join order.
sort_by_priority(Ids, S) ->
    lists:sort(
      fun(A, B) ->
          DA = data_of(A, S), DB = data_of(B, S),
          case DA =:= DB of
              true -> join_pos(A, S) =< join_pos(B, S);
              false -> DA > DB
          end
      end, Ids).

data_of(Id, S) ->
    maps:get(data, maps:get(Id, S#state.subs)).

join_pos(Id, S) ->
    index_at(Id, S#state.join_order, 0).

%% Broadcast the extraction announcement for each revealed leader.
announce_leaders(_S, []) -> ok;
announce_leaders(S, Leaders) ->
    [begin
         Sub = maps:get(Id, S#state.subs),
         broadcast(S, <<"extraction_announced">>,
                   #{<<"player_id">> => Id,
                     <<"data_collected">> => maps:get(data, Sub),
                     <<"x">> => maps:get(x, Sub),
                     <<"y">> => maps:get(y, Sub)})
     end || Id <- Leaders],
    ok.

%% End the match: announce the winner and stop dealing rounds.
end_match(S, Winner, Reason, RunnerUp) ->
    logger:info("stw game ~s over (winner=~p reason=~s round=~p)",
                [S#state.room_code, Winner, Reason, S#state.round]),
    S1 = S#state{phase = finished, winner = Winner,
                 finish_reason = Reason, runner_up = RunnerUp,
                 programs = #{}, locked = [], submitted = #{},
                 revealed = alive_ids(S),
                 timer_ref = undefined, timer_ends = undefined},
    broadcast(S1, <<"game_over">>, game_over_payload(S1, Winner, Reason, RunnerUp)),
    %% Send one final, fully revealed state so everyone sees the finish.
    broadcast_game_state(S1),
    S1.

game_over_payload(S, Winner, Reason, RunnerUp) ->
    #{<<"winner">> => null_or(Winner),
      <<"reason">> => Reason,
      <<"runner_up">> => null_or(RunnerUp),
      <<"standings">> => standings_json(S)}.

standings_json(S) ->
    [begin
         Idx = index_at(Id, S#state.join_order, 0),
         Sub = maps:get(Id, S#state.subs),
         P = maps:get(Id, S#state.players, #{}),
         #{<<"player_id">> => Id,
           <<"display_name">> => maps:get(display_name, P, Id),
           <<"color">> => color_for(Idx),
           <<"data_collected">> => maps:get(data, Sub),
           <<"hull">> => maps:get(hull, Sub),
           <<"alive">> => maps:get(alive, Sub)}
     end || Id <- S#state.join_order, maps:is_key(Id, S#state.subs)].

null_or(undefined) -> null;
null_or(V) -> V.

%% Scan the resolved phases for sonar pings that hit, and privately push the
%% revealed program of each victim to the shooter that pinged them.
reveal_sonar_hits(S, Phases) ->
    Hits = lists:usort(
             [{maps:get(<<"player_id">>, E), maps:get(<<"hit">>, E)}
              || P <- Phases, E <- maps:get(<<"events">>, P),
                 maps:get(<<"type">>, E) =:= <<"sonar_ping">>,
                 maps:get(<<"hit">>, E, null) =/= null]),
    lists:foreach(
      fun({Shooter, Target}) ->
          case maps:find(Target, S#state.programs) of
              {ok, Registers} ->
                  push(ws_of(Shooter, S), <<"revealed_cards">>,
                       #{<<"player_id">> => Target,
                         <<"round">> => S#state.round,
                         <<"registers">> => Registers});
              error ->
                  ok
          end
      end, Hits).

%% --- ping timer -------------------------------------------------------

%% Start the 30s Ping Timer on the first lock of the round.
maybe_start_timer(S) when S#state.timer_ref =/= undefined -> S;
maybe_start_timer(S) ->
    Ref = erlang:send_after(ping_timer_ms(), self(), ping_timeout),
    Ends = now_ms() + ping_timer_ms(),
    S1 = S#state{timer_ref = Ref, timer_ends = Ends},
    broadcast(S1, <<"timer_started">>, timer_payload(S1)),
    S1.

cancel_timer(S) when S#state.timer_ref =:= undefined -> S;
cancel_timer(S) ->
    erlang:cancel_timer(S#state.timer_ref),
    S#state{timer_ref = undefined, timer_ends = undefined}.

maybe_push_timer(S, _WsPid) when S#state.timer_ref =:= undefined -> ok;
maybe_push_timer(S, WsPid) ->
    push(WsPid, <<"timer_started">>, timer_payload(S)).

now_ms() -> erlang:system_time(millisecond).

%% --- lookups ----------------------------------------------------------

seated_ids(S) ->
    [Id || Id <- S#state.join_order,
           maps:is_key(Id, S#state.subs),
           is_alive(Id, S)].

is_alive(PlayerId, S) ->
    maps:get(alive, maps:get(PlayerId, S#state.subs), true).

hull_of(PlayerId, S) ->
    maps:get(hull, maps:get(PlayerId, S#state.subs)).

ws_of(PlayerId, S) ->
    case maps:find(PlayerId, S#state.players) of
        {ok, #{ws_pid := WsPid}} -> WsPid;
        _ -> undefined
    end.

submarines_json(S) ->
    [sub_json(Idx, Id, S)
     || {Idx, Id} <- enumerate(S#state.join_order),
        maps:is_key(Id, S#state.subs)].

%% 0-based position of a player in join order (its stable color index).
index_of(Id, S) ->
    index_at(Id, S#state.join_order, 0).

index_at(Id, [Id | _], N) -> N;
index_at(Id, [_ | T], N) -> index_at(Id, T, N + 1);
index_at(_, [], _) -> 0.

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
      <<"alive">> => maps:get(alive, Sub, true),
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
      alive => true,
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
