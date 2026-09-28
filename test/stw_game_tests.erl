%%%-------------------------------------------------------------------
%% @doc Integration tests for the Phase 1 lobby + game session flow.
%%
%% These start the lobby and game supervisor directly (without Cowboy)
%% and use the test process as a stand-in WebSocket connection pid, so
%% we can assert on the {push, Type, Payload} messages the game emits.
%% @end
%%%-------------------------------------------------------------------
-module(stw_game_tests).

-include_lib("eunit/include/eunit.hrl").

lobby_flow_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [ fun create_and_join/0,
          fun room_not_found/0,
          fun reconnect_resumes_room/0,
          fun reconnect_to_finished_game/0,
          fun host_starts_game/0,
          fun full_round_resolves/0,
          fun deals_full_hand/0,
          fun timeout_autofills/0,
          fun fog_hides_distant_enemy/0,
          fun active_sonar_reveals/0,
          fun objectives_in_game_state/0,
          fun map_selection_uses_named_board/0,
          fun map_collapse_after_interval/0,
          fun host_adds_bot/0,
          fun bot_add_requires_host_and_room/0,
          fun bot_plays_and_resolves/0 ]
    end}.

setup() ->
    application:ensure_all_started(crypto),
    {ok, SupPid} = stw_game_sup:start_link(),
    {ok, LobbyPid} = stw_lobby:start_link(),
    {SupPid, LobbyPid}.

cleanup(_) ->
    catch gen_server:stop(stw_lobby),
    catch stop_sup(whereis(stw_game_sup)),
    timer:sleep(30),
    ok.

stop_sup(undefined) -> ok;
stop_sup(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown).

%% Host creates a room; a second player joins; both see a 2-player lobby.
create_and_join() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Alice">>),
    {ok, Room, GamePid} = stw_lobby:create_game(T1, #{}),
    ?assertEqual(6, byte_size(Room)),
    {ok, true} = stw_game:join(GamePid, P1, <<"Alice">>, self()),
    L1 = expect_push(<<"lobby_state">>),
    ?assertEqual(1, length(maps:get(<<"players">>, L1))),
    ?assertEqual(P1, maps:get(<<"host_id">>, L1)),

    {P2, T2, undefined} = stw_lobby:hello(undefined, <<"Bob">>),
    {ok, GamePid} = stw_lobby:join_room(T2, Room),
    {ok, false} = stw_game:join(GamePid, P2, <<"Bob">>, self()),
    L2 = expect_push(<<"lobby_state">>),
    ?assertEqual(2, length(maps:get(<<"players">>, L2))).

room_not_found() ->
    {_P, T, _} = stw_lobby:hello(undefined, <<"Nobody">>),
    ?assertEqual({error, room_not_found},
                 stw_lobby:join_room(T, <<"ZZZZZZ">>)).

%% Resolving a room and reconnecting pushes current state to the new pid.
reconnect_resumes_room() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Cara">>),
    {ok, Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Cara">>, self()),
    _ = expect_push(<<"lobby_state">>),
    {ok, GamePid} = stw_lobby:lookup_room(Room),
    ok = stw_game:reconnect(GamePid, P1, self()),
    L = expect_push(<<"lobby_state">>),
    [Player] = maps:get(<<"players">>, L),
    ?assertEqual(true, maps:get(<<"connected">>, Player)).

%% Reconnecting to a match that has already finished must not crash the
%% game server; it replays the final state and game_over to the client.
%% We drive the game into the finished phase with sys:replace_state so the
%% test stays deterministic (record fields: phase=6, winner=24,
%% finish_reason=25 in stw_game's #state{}).
reconnect_to_finished_game() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Dana">>),
    {ok, Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Dana">>, self()),
    _ = expect_push(<<"lobby_state">>),
    ok = stw_game:start_game(GamePid, P1),
    _ = expect_push(<<"game_started">>),
    flush(),
    sys:replace_state(GamePid, fun(S0) ->
        S1 = setelement(6, S0, finished),      %% phase
        S2 = setelement(24, S1, P1),           %% winner
        setelement(25, S2, <<"survivor">>)     %% finish_reason
    end),
    {ok, GamePid} = stw_lobby:lookup_room(Room),
    ok = stw_game:reconnect(GamePid, P1, self()),
    GO = expect_push(<<"game_over">>),
    ?assertEqual(P1, maps:get(<<"winner">>, GO)),
    ?assertEqual(<<"survivor">>, maps:get(<<"reason">>, GO)),
    %% Server is still alive and responsive after the reconnect.
    ?assert(is_process_alive(GamePid)).

%% Only the host can start; starting broadcasts game_started.
host_starts_game() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Host">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Host">>, self()),
    _ = expect_push(<<"lobby_state">>),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Crew">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Crew">>, self()),
    _ = expect_push(<<"lobby_state">>),
    ?assertEqual({error, not_host}, stw_game:start_game(GamePid, P2)),
    ok = stw_game:start_game(GamePid, P1),
    GS = expect_push(<<"game_started">>),
    Subs = maps:get(<<"submarines">>, GS),
    ?assertEqual(2, length(Subs)),
    Board = maps:get(<<"board">>, GS),
    ?assertEqual(20, maps:get(<<"width">>, Board)),
    %% each submarine is placed on a real coordinate with a full hull
    [begin
         ?assert(is_integer(maps:get(<<"x">>, Sub))),
         ?assert(is_integer(maps:get(<<"y">>, Sub))),
         ?assertEqual(10, maps:get(<<"hull">>, Sub)),
         ?assertEqual(<<"shallow">>, maps:get(<<"depth">>, Sub))
     end || Sub <- Subs].

%% Starting broadcasts round_started; both players draft 5 cards from their
%% private hands and lock; the round resolves into a round_result carrying 5
%% phases and final submarines.
full_round_resolves() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Skipper">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Skipper">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Mate">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Mate">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    RS = expect_push(<<"round_started">>),
    ?assertEqual(1, maps:get(<<"round">>, RS)),
    ?assertEqual(5, maps:get(<<"registers">>, RS)),

    Prog1 = draft(deal_for(P1)),
    Prog2 = draft(deal_for(P2)),
    ok = stw_game:program_registers(GamePid, P1, Prog1),
    ok = stw_game:program_registers(GamePid, P2, Prog2),
    %% a bad program (wrong size / unknown ids) is rejected without resolving
    ?assertEqual({error, invalid_register},
                 stw_game:program_registers(GamePid, P1, [<<"nope">>])),
    flush(),
    ok = stw_game:lock_registers(GamePid, P1),
    %% the first lock starts the 30s Ping Timer
    TS = expect_push(<<"timer_started">>),
    ?assertEqual(30000, maps:get(<<"duration_ms">>, TS)),
    ?assert(is_integer(maps:get(<<"ends_at">>, TS))),
    _ = expect_push(<<"player_locked">>),
    ok = stw_game:lock_registers(GamePid, P2),

    %% all locked -> resolving with no auto-filled players
    Res = expect_push(<<"registers_resolving">>),
    ?assertEqual([], maps:get(<<"auto_filled">>, Res)),
    RR = expect_push(<<"round_result">>),
    ?assertEqual(1, maps:get(<<"round">>, RR)),
    Phases = maps:get(<<"phases">>, RR),
    ?assertEqual(5, length(Phases)),
    [Ph0 | _] = Phases,
    ?assertEqual(0, maps:get(<<"register">>, Ph0)),
    %% round_result is now fogged per player: the first push is P1's view,
    %% and with the two spawns at opposite corners P1 only sees itself.
    ?assert(has_sub(P1, maps:get(<<"submarines">>, Ph0))),
    ?assert(has_sub(P1, maps:get(<<"submarines">>, RR))),

    %% after resolution a fresh round is announced with fresh hands
    RS2 = expect_push(<<"round_started">>),
    ?assertEqual(2, maps:get(<<"round">>, RS2)).

%% At full hull, each player is dealt a 9-card hand.
deals_full_hand() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Ivy">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Ivy">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Jax">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Jax">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    Deal = deal_for(P1),
    Cards = maps:get(<<"cards">>, Deal),
    ?assertEqual(9, length(Cards)),
    ?assert(has_card_group(Cards, stw_engine:ahead_cards())),
    ?assert(has_card_group(Cards, stw_engine:turn_cards())),
    Kinds = stw_engine:card_kinds(),
    [begin
         ?assert(is_binary(maps:get(<<"id">>, C))),
         ?assert(lists:member(maps:get(<<"kind">>, C), Kinds))
     end || C <- Cards].

%% When the Ping Timer expires, unlocked players' registers are auto-filled
%% and the round still resolves.
timeout_autofills() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Nel">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Nel">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Ozy">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Ozy">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    Prog1 = draft(deal_for(P1)),
    _ = deal_for(P2),
    ok = stw_game:program_registers(GamePid, P1, Prog1),
    ok = stw_game:lock_registers(GamePid, P1),
    _ = expect_push(<<"timer_started">>),
    %% simulate the 30s timer firing without waiting
    GamePid ! ping_timeout,
    Res = expect_push(<<"registers_resolving">>),
    ?assertEqual([P2], maps:get(<<"auto_filled">>, Res)),
    RR = expect_push(<<"round_result">>),
    ?assertEqual(5, length(maps:get(<<"phases">>, RR))).

%% Distant enemies are hidden by fog of war: at opposite spawn corners in
%% passive mode a player sees only its own submarine.
fog_hides_distant_enemy() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Rex">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Rex">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Syl">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Syl">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    GS = game_state_for(P1),
    ?assertEqual(false, maps:get(<<"spectator">>, GS)),
    Subs = maps:get(<<"submarines">>, GS),
    ?assert(has_sub(P1, Subs)),
    ?assertNot(has_sub(P2, Subs)),
    ?assert(length(maps:get(<<"visible_tiles">>, GS)) > 0).

%% Switching to active sonar reveals a player to everyone, even across the
%% board, and re-broadcasts fresh views to all seated players.
active_sonar_reveals() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Uma">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Uma">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Vic">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Vic">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    _ = game_state_for(P1),
    ok = stw_game:set_sonar_mode(GamePid, P2, <<"active">>),
    GS = game_state_for(P1),
    ?assert(has_sub(P2, maps:get(<<"submarines">>, GS))).

%% The per-player game_state carries the Phase 7 objective layer: the
%% moving extraction zone, the win threshold, and a (possibly empty) list
%% of visible data nodes.
objectives_in_game_state() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Wes">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Wes">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Xan">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Xan">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    GS = game_state_for(P1),
    Ext = maps:get(<<"extraction">>, GS),
    ?assert(is_integer(maps:get(<<"x">>, Ext))),
    ?assert(is_integer(maps:get(<<"y">>, Ext))),
    ?assertEqual(3, maps:get(<<"win_data">>, GS)),
    ?assert(is_list(maps:get(<<"data_nodes">>, GS))),
    %% Phase 8: the fog view also carries a (starts-empty) decoy contact list.
    ?assertEqual([], maps:get(<<"decoys">>, GS)).

%% Phase 9: choosing a map id at create time seats players on that named
%% board. Trench Bravo carries a horizontal ledge at y=4 (x=1..13), so the
%% game_started grid row 4 shows rock where Trench Alpha would be open.
map_selection_uses_named_board() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Yara">>),
    {ok, _Room, GamePid} =
        stw_lobby:create_game(T1, #{map_id => <<"trench_beta">>}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Yara">>, self()),
    L = expect_push(<<"lobby_state">>),
    ?assertEqual(<<"trench_beta">>, maps:get(<<"map_id">>, L)),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Zed">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Zed">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    GS = expect_push(<<"game_started">>),
    ?assertEqual(<<"trench_beta">>, maps:get(<<"map_id">>, GS)),
    Grid = maps:get(<<"grid">>, maps:get(<<"board">>, GS)),
    Row4 = lists:nth(5, Grid),
    ?assertEqual($#, binary:at(Row4, 3)).

%% Phase 9: every third round the trench collapses. Play two full rounds and
%% the game broadcasts a map_collapse naming the round and the walled tiles.
map_collapse_after_interval() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Ada">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Ada">>, self()),
    {P2, _T2, _} = stw_lobby:hello(undefined, <<"Bly">>),
    {ok, false} = stw_game:join(GamePid, P2, <<"Bly">>, self()),
    flush(),
    ok = stw_game:start_game(GamePid, P1),
    _ = expect_push(<<"round_started">>),
    play_round(GamePid, P1, P2),
    _ = expect_push(<<"round_started">>),
    play_round(GamePid, P1, P2),
    Collapse = expect_push(<<"map_collapse">>),
    ?assertEqual(3, maps:get(<<"round">>, Collapse)),
    Tiles = maps:get(<<"tiles">>, Collapse),
    ?assert(length(Tiles) >= 1),
    [begin
         ?assert(is_integer(maps:get(<<"x">>, Tile))),
         ?assert(is_integer(maps:get(<<"y">>, Tile)))
     end || Tile <- Tiles].

%% --- pure game-logic tests --------------------------------------------

ensure_movement_keeps_existing_categories_test() ->
    Hand = [#{<<"id">> => <<"c1">>, <<"kind">> => <<"torpedo">>},
            #{<<"id">> => <<"c2">>, <<"kind">> => <<"ahead_flank">>},
            #{<<"id">> => <<"c3">>, <<"kind">> => <<"dive">>},
            #{<<"id">> => <<"c4">>, <<"kind">> => <<"port_bank">>},
            #{<<"id">> => <<"c5">>, <<"kind">> => <<"surface">>}],
    ?assertEqual(Hand, stw_game:ensure_movement(Hand)).

ensure_movement_adds_both_categories_test() ->
    Hand = [#{<<"id">> => <<"c1">>, <<"kind">> => <<"torpedo">>},
            #{<<"id">> => <<"c2">>, <<"kind">> => <<"depth_charge">>},
            #{<<"id">> => <<"c3">>, <<"kind">> => <<"dive">>},
            #{<<"id">> => <<"c4">>, <<"kind">> => <<"surface">>},
            #{<<"id">> => <<"c5">>, <<"kind">> => <<"reverse">>}],
    Fixed = stw_game:ensure_movement(Hand),
    ?assertEqual(length(Hand), length(Fixed)),
    ?assertEqual([<<"c1">>, <<"c2">>, <<"c3">>, <<"c4">>, <<"c5">>],
                 [maps:get(<<"id">>, C) || C <- Fixed]),
    ?assert(has_card_group(Fixed, stw_engine:ahead_cards())),
    ?assert(has_card_group(Fixed, stw_engine:turn_cards())).

ensure_movement_preserves_existing_turn_test() ->
    Hand = [#{<<"id">> => <<"c1">>, <<"kind">> => <<"port_bank">>},
            #{<<"id">> => <<"c2">>, <<"kind">> => <<"torpedo">>},
            #{<<"id">> => <<"c3">>, <<"kind">> => <<"depth_charge">>},
            #{<<"id">> => <<"c4">>, <<"kind">> => <<"dive">>},
            #{<<"id">> => <<"c5">>, <<"kind">> => <<"surface">>}],
    Fixed = stw_game:ensure_movement(Hand),
    ?assertEqual(<<"port_bank">>, maps:get(<<"kind">>, hd(Fixed))),
    ?assert(has_card_group(Fixed, stw_engine:ahead_cards())),
    ?assert(has_card_group(Fixed, stw_engine:turn_cards())).

ensure_movement_preserves_existing_ahead_test() ->
    Hand = [#{<<"id">> => <<"c1">>, <<"kind">> => <<"ahead_standard">>},
            #{<<"id">> => <<"c2">>, <<"kind">> => <<"torpedo">>},
            #{<<"id">> => <<"c3">>, <<"kind">> => <<"depth_charge">>},
            #{<<"id">> => <<"c4">>, <<"kind">> => <<"dive">>},
            #{<<"id">> => <<"c5">>, <<"kind">> => <<"surface">>}],
    Fixed = stw_game:ensure_movement(Hand),
    ?assertEqual(<<"ahead_standard">>, maps:get(<<"kind">>, hd(Fixed))),
    ?assert(has_card_group(Fixed, stw_engine:ahead_cards())),
    ?assert(has_card_group(Fixed, stw_engine:turn_cards())).

has_card_group(Cards, Kinds) ->
    lists:any(fun(#{<<"kind">> := Kind}) -> lists:member(Kind, Kinds) end,
              Cards).

%% A submarine ending its round on a data node downloads it: its data count
%% rises and the node is removed from the board.
collect_data_node_test() ->
    Subs = #{<<"a">> => sub(3, 5, 0)},
    {Subs1, Nodes1} = stw_game:resolve_data(Subs, [{3, 5}, {8, 8}], []),
    ?assertEqual(1, maps:get(data, maps:get(<<"a">>, Subs1))),
    ?assertEqual([{8, 8}], Nodes1).

%% A submarine that is not standing on a node collects nothing.
no_collect_off_node_test() ->
    Subs = #{<<"a">> => sub(4, 4, 0)},
    {Subs1, Nodes1} = stw_game:resolve_data(Subs, [{3, 5}], []),
    ?assertEqual(0, maps:get(data, maps:get(<<"a">>, Subs1))),
    ?assertEqual([{3, 5}], Nodes1).

%% Only one submarine collects a shared node tile (deterministic by id).
one_collector_per_node_test() ->
    Subs = #{<<"a">> => sub(3, 5, 0), <<"b">> => sub(3, 5, 0)},
    {Subs1, Nodes1} = stw_game:resolve_data(Subs, [{3, 5}], []),
    Total = maps:get(data, maps:get(<<"a">>, Subs1)) +
            maps:get(data, maps:get(<<"b">>, Subs1)),
    ?assertEqual(1, Total),
    ?assertEqual([], Nodes1).

%% A torpedoed submarine carrying data drops one recoverable node on its tile.
data_theft_drops_node_test() ->
    Subs = #{<<"a">> => sub(7, 7, 2)},
    Phases = [#{<<"events">> =>
                [#{<<"type">> => <<"hit">>, <<"player_id">> => <<"a">>,
                   <<"weapon">> => <<"torpedo">>, <<"damage">> => 2}]}],
    {Subs1, Nodes1} = stw_game:resolve_data(Subs, [], Phases),
    ?assertEqual(1, maps:get(data, maps:get(<<"a">>, Subs1))),
    ?assertEqual([{7, 7}], Nodes1).

%% The patrolling extraction path is non-empty and rides the top interior row.
extraction_path_test() ->
    Path = stw_game:extraction_path(stw_board:default()),
    ?assert(length(Path) >= 1),
    [?assertEqual(1, Y) || {_X, Y} <- Path].

%% The host can add a computer opponent; it appears in the lobby as an
%% auto-ready bot player and counts toward the roster.
host_adds_bot() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Skip">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Skip">>, self()),
    _ = expect_push(<<"lobby_state">>),
    {ok, BotId} = stw_game:add_bot(GamePid, P1),
    L = expect_push(<<"lobby_state">>),
    Players = maps:get(<<"players">>, L),
    ?assertEqual(2, length(Players)),
    [Bot] = [Pl || Pl <- Players,
                   maps:get(<<"player_id">>, Pl) =:= BotId],
    ?assertEqual(true, maps:get(<<"bot">>, Bot)),
    ?assertEqual(true, maps:get(<<"ready">>, Bot)),
    ?assertEqual(true, maps:get(<<"connected">>, Bot)),
    %% the human is still the host, not the bot
    ?assertEqual(P1, maps:get(<<"host_id">>, L)).

%% Only the host may add bots, and not once the room is full.
bot_add_requires_host_and_room() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Boss">>),
    {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{max_players => 2}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Boss">>, self()),
    _ = expect_push(<<"lobby_state">>),
    %% a non-host (not even seated) cannot add a bot
    ?assertEqual({error, not_host},
                 stw_game:add_bot(GamePid, <<"stranger">>)),
    %% host fills the last slot with a bot, then the room is full
    {ok, _Bot} = stw_game:add_bot(GamePid, P1),
    _ = expect_push(<<"lobby_state">>),
    ?assertEqual({error, room_full}, stw_game:add_bot(GamePid, P1)).

%% A bot programs and locks on its own, so a round resolves once the human
%% also locks, and the match proceeds to the next round.
bot_plays_and_resolves() ->
    Prev = application:get_env(stw, bot_delay_ms),
    application:set_env(stw, bot_delay_ms, 0),
    try
        flush(),
        {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Solo">>),
        {ok, _Room, GamePid} = stw_lobby:create_game(T1, #{}),
        {ok, true} = stw_game:join(GamePid, P1, <<"Solo">>, self()),
        {ok, _Bot} = stw_game:add_bot(GamePid, P1),
        flush(),
        ok = stw_game:start_game(GamePid, P1),
        _ = expect_push(<<"round_started">>),
        Prog1 = draft(deal_for(P1)),
        ok = stw_game:program_registers(GamePid, P1, Prog1),
        ok = stw_game:lock_registers(GamePid, P1),
        %% both the human and the bot have locked -> the round resolves
        RR = expect_push(<<"round_result">>),
        ?assertEqual(1, maps:get(<<"round">>, RR)),
        ?assertEqual(5, length(maps:get(<<"phases">>, RR))),
        %% a fresh round is announced, proving the bot keeps playing
        RS2 = expect_push(<<"round_started">>),
        ?assertEqual(2, maps:get(<<"round">>, RS2))
    after
        case Prev of
            undefined -> application:unset_env(stw, bot_delay_ms);
            {ok, V} -> application:set_env(stw, bot_delay_ms, V)
        end
    end.

sub(X, Y, Data) ->
    #{x => X, y => Y, facing => <<"N">>, depth => <<"shallow">>,
      hull => 10, alive => true, data => Data}.

%% --- helpers ----------------------------------------------------------

expect_push(Type) ->
    receive
        {push, Type, Payload} -> Payload
    after 1000 ->
        erlang:error({timeout_waiting_for, Type})
    end.

%% Selectively receive the personalized game_state for a specific player.
game_state_for(PlayerId) ->
    receive
        {push, <<"game_state">>,
         #{<<"you">> := #{<<"player_id">> := PlayerId}} = Payload} ->
            Payload
    after 1000 ->
        erlang:error({timeout_game_state, PlayerId})
    end.

%% True when a submarine snapshot list contains the given player.
has_sub(PlayerId, Subs) ->
    lists:any(fun(Su) -> maps:get(<<"player_id">>, Su) =:= PlayerId end, Subs).

%% Selectively receive the private deal_hand for a specific player.
deal_for(PlayerId) ->
    receive
        {push, <<"deal_hand">>, #{<<"player_id">> := PlayerId} = Payload} ->
            Payload
    after 1000 ->
        erlang:error({timeout_deal, PlayerId})
    end.

%% Pick the first 5 card IDs out of a dealt hand payload.
draft(Deal) ->
    Cards = maps:get(<<"cards">>, Deal),
    [maps:get(<<"id">>, C) || C <- lists:sublist(Cards, 5)].

%% Draft, program and lock both players so the current round fully resolves.
play_round(GamePid, P1, P2) ->
    Prog1 = draft(deal_for(P1)),
    Prog2 = draft(deal_for(P2)),
    ok = stw_game:program_registers(GamePid, P1, Prog1),
    ok = stw_game:program_registers(GamePid, P2, Prog2),
    ok = stw_game:lock_registers(GamePid, P1),
    ok = stw_game:lock_registers(GamePid, P2),
    ok.

flush() ->
    receive _ -> flush() after 0 -> ok end.
