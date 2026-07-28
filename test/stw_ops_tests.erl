%%%-------------------------------------------------------------------
%% @doc Tests for Phase 12 operability additions: lobby stats snapshot,
%% the /metrics payload, and env-driven gameplay tunables.
%% @end
%%%-------------------------------------------------------------------
-module(stw_ops_tests).

-include_lib("eunit/include/eunit.hrl").

ops_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [fun stats_reports_active_games/0,
      fun stats_counts_players_in_rooms/0,
      fun metrics_snapshot_has_core_fields/0,
      fun metrics_survives_lobby_down/0]}.

setup() ->
    {ok, GS} = stw_game_sup:start_link(),
    {ok, Lob} = stw_lobby:start_link(),
    {GS, Lob}.

cleanup({GS, Lob}) ->
    _ = stop(Lob),
    _ = stop(GS),
    ok.

stop(Pid) when is_pid(Pid) ->
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok
    after 2000 -> ok end.

%% --- lobby stats ------------------------------------------------------

stats_reports_active_games() ->
    Empty = stw_lobby:stats(),
    ?assertEqual(0, maps:get(<<"active_games">>, Empty)),
    {_, _, undefined} = stw_lobby:hello(undefined, <<"Host">>),
    S0 = stw_lobby:stats(),
    Before = maps:get(<<"active_games">>, S0),
    {ok, _Room, _Pid} = create_via_hello(<<"Ann">>),
    S1 = stw_lobby:stats(),
    ?assertEqual(Before + 1, maps:get(<<"active_games">>, S1)).

stats_counts_players_in_rooms() ->
    {ok, Room, _Pid} = create_via_hello(<<"Bea">>),
    {_, TokC, undefined} = stw_lobby:hello(undefined, <<"Cid">>),
    {ok, _} = stw_lobby:join_room(TokC, Room),
    Stats = stw_lobby:stats(),
    ?assert(maps:get(<<"players_in_rooms">>, Stats) >= 2),
    ?assert(maps:get(<<"tracked_sessions">>, Stats) >= 2).

%% --- metrics payload --------------------------------------------------

metrics_snapshot_has_core_fields() ->
    M = stw_health_handler:metrics(),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, M)),
    ?assert(is_integer(maps:get(<<"uptime_ms">>, M))),
    ?assert(maps:is_key(<<"active_games">>, M)),
    ?assert(maps:is_key(<<"players_in_rooms">>, M)),
    %% Payload must be JSON-encodable for the HTTP endpoint.
    _ = iolist_to_binary(json:encode(M)),
    ok.

metrics_survives_lobby_down() ->
    %% Temporarily unregister the lobby so stats/0 would fail; the
    %% endpoint must still return a safe snapshot rather than crash.
    Pid = whereis(stw_lobby),
    true = is_pid(Pid),
    unregister(stw_lobby),
    try
        M = stw_health_handler:metrics(),
        ?assertEqual(0, maps:get(<<"active_games">>, M))
    after
        register(stw_lobby, Pid)
    end.

%% --- helpers ----------------------------------------------------------

create_via_hello(Name) ->
    {_, Tok, _} = stw_lobby:hello(undefined, Name),
    stw_lobby:create_game(Tok, #{}).

%% --- config tunables (no lobby/game processes needed) -----------------

config_defaults_test() ->
    clear_env(),
    ?assertEqual(9, stw_game:base_hand()),
    ?assertEqual(5, stw_game:min_hand()),
    ?assertEqual(3, stw_game:win_data()),
    ?assertEqual(30000, stw_game:ping_timer_ms()),
    ?assertEqual(3, stw_game:collapse_interval()).

config_env_override_test() ->
    try
        application:set_env(stw, win_data, 5),
        application:set_env(stw, ping_timer_ms, 12000),
        application:set_env(stw, collapse_interval, 2),
        ?assertEqual(5, stw_game:win_data()),
        ?assertEqual(12000, stw_game:ping_timer_ms()),
        ?assertEqual(2, stw_game:collapse_interval())
    after
        clear_env()
    end.

clear_env() ->
    [application:unset_env(stw, K)
     || K <- [base_hand, min_hand, win_data, ping_timer_ms, collapse_interval]],
    ok.
