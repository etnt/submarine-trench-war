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
          fun host_starts_game/0 ]
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
    ?assertEqual(2, length(maps:get(<<"players">>, GS))).

%% --- helpers ----------------------------------------------------------

expect_push(Type) ->
    receive
        {push, Type, Payload} -> Payload
    after 1000 ->
        erlang:error({timeout_waiting_for, Type})
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
