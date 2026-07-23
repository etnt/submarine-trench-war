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
          fun host_starts_game/0,
          fun full_round_resolves/0,
          fun deals_full_hand/0,
          fun timeout_autofills/0 ]
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
    ?assertEqual(2, length(maps:get(<<"submarines">>, Ph0))),
    ?assertEqual(2, length(maps:get(<<"submarines">>, RR))),

    %% after resolution a fresh round is announced with fresh hands
    RS2 = expect_push(<<"round_started">>),
    ?assertEqual(2, maps:get(<<"round">>, RS2)).

%% At full hull each player is dealt a 9-card navigation hand.
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

%% --- helpers ----------------------------------------------------------

expect_push(Type) ->
    receive
        {push, Type, Payload} -> Payload
    after 1000 ->
        erlang:error({timeout_waiting_for, Type})
    end.

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

flush() ->
    receive _ -> flush() after 0 -> ok end.
