%%%-------------------------------------------------------------------
%% @doc Phase 11 hardening: cross-session integration, concurrency/load,
%% reconnection & timeout robustness, and server-authority (anti-cheat)
%% tests for the live game session process.
%%
%% These start the lobby and game supervisor directly (no Cowboy) and use
%% the test process (or throwaway pids) as stand-in WebSocket connections,
%% asserting on the {push, Type, Payload} messages the game emits. The
%% focus is on properties that only emerge with real gen_server sessions:
%%   * two concurrent matches never leak state into each other
%%   * many matches run many rounds without crashing or leaking processes
%%   * a mid-round reconnect restores the player's authoritative program
%%   * a dropped socket keeps the player in the room, resumable later
%%   * stray/stale/garbage messages never take a session down
%%   * the server is authoritative: malformed or forged programs are
%%     rejected, only the host starts, and outsiders cannot act on a room
%% @end
%%%-------------------------------------------------------------------
-module(stw_integration_tests).

-include_lib("eunit/include/eunit.hrl").

%% Navigation card kinds (safe to program without triggering combat).
-define(NAV, [<<"ahead_standard">>, <<"ahead_flank">>, <<"reverse">>,
              <<"port_bank">>, <<"starboard_bank">>, <<"dive">>,
              <<"surface">>]).

hardening_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [ {"concurrent games stay isolated", fun concurrent_games_are_isolated/0},
          {"many games survive load", {timeout, 60, fun many_games_survive_load/0}},
          {"garbage messages never crash a session", fun garbage_is_ignored/0},
          {"mid-round reconnect restores program", fun reconnect_restores_program/0},
          {"dropped socket keeps player resumable", fun drop_then_reconnect/0},
          {"stale ping timeout in lobby is a no-op", fun stale_timeout_is_safe/0},
          {"partial programs survive a timeout", fun timeout_preserves_partial/0},
          {"only the host can start", fun only_host_starts/0},
          {"host cannot restart a match", fun host_cannot_restart/0},
          {"cannot act before the match starts", fun no_act_before_start/0},
          {"forged and malformed programs are rejected", fun rejects_bad_programs/0},
          {"outsiders cannot program a room", fun outsider_cannot_program/0},
          {"locked programs cannot be replaced", fun locked_program_cannot_change/0},
          {"cannot lock without a program", fun no_lock_without_program/0} ]
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

%% --- multi-session isolation ------------------------------------------

%% Two matches run at once. A player from one is a stranger to the other,
%% and each resolves its own round and advances its own round counter with
%% no cross-talk.
concurrent_games_are_isolated() ->
    flush(),
    {GA, [A1, A2]} = started_game(1),
    {GB, [B1, B2]} = started_game(1),
    ?assertNotEqual(GA, GB),
    %% A1 belongs to game A only: game B does not know it.
    ?assertEqual({error, not_in_game},
                 stw_game:program_registers(GB, A1, [])),
    %% each match resolves an independent round
    play_round(GA, [A1, A2]),
    play_round(GB, [B1, B2]),
    %% both matches deal a fresh round-2 hand to their own players
    ?assertEqual(2, maps:get(<<"round">>, deal_for(A1))),
    ?assertEqual(2, maps:get(<<"round">>, deal_for(B1))),
    ?assert(has_hand(A2)),
    ?assert(has_hand(B2)).

%% --- concurrency / load -----------------------------------------------

%% A batch of matches, each with several players, plays multiple rounds of
%% stationary "hold" programs. Every session must survive the load and stay
%% responsive, and no game process may leak once the batch is torn down.
many_games_survive_load() ->
    flush(),
    NumGames = 8,
    Rounds = 3,
    Games = [started_game(2) || _ <- lists:seq(1, NumGames)],
    lists:foreach(
      fun({GamePid, Players}) ->
          [play_holds(GamePid, Players) || _ <- lists:seq(1, Rounds)]
      end, Games),
    %% every session survived and still answers calls
    [?assert(is_process_alive(G)) || {G, _} <- Games],
    [?assertEqual({error, unknown_request}, gen_server:call(G, are_you_ok))
     || {G, _} <- Games],
    %% tearing every match down leaves no lingering game workers
    [begin
         ok = stw_game:leave(G, P) end
     || {G, Ps} <- Games, P <- Ps],
    timer:sleep(50),
    [?assertNot(is_process_alive(G)) || {G, _} <- Games].

%% --- robustness against bad input -------------------------------------

%% Unknown calls, casts and info messages must never take a session down.
garbage_is_ignored() ->
    flush(),
    {GamePid, _Players} = started_game(1),
    ?assertEqual({error, unknown_request}, gen_server:call(GamePid, nonsense)),
    gen_server:cast(GamePid, {who, knows}),
    GamePid ! surprise,
    GamePid ! {push, <<"not">>, <<"real">>},
    %% still alive and responsive after the barrage
    ?assert(is_process_alive(GamePid)),
    ?assertEqual({error, unknown_request}, gen_server:call(GamePid, still_there)).

%% --- reconnection robustness ------------------------------------------

%% After a player programs and locks, a mid-round reconnect must replay the
%% authoritative locked program back to the fresh socket.
reconnect_restores_program() ->
    flush(),
    {GamePid, [P1, P2]} = started_game(1),
    Prog = draft_nav(deal_for(P1)),
    _ = deal_for(P2),
    ok = stw_game:program_registers(GamePid, P1, Prog),
    ok = stw_game:lock_registers(GamePid, P1),
    flush(),
    ok = stw_game:reconnect(GamePid, P1, self()),
    PR = expect_push(<<"program_restored">>),
    ?assertEqual(true, maps:get(<<"locked">>, PR)),
    ?assertEqual(length(Prog), length(maps:get(<<"registers">>, PR))).

%% A dropped WebSocket marks the player disconnected but keeps them in the
%% room; reconnecting on a new socket brings them back as connected.
drop_then_reconnect() ->
    flush(),
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Host">>),
    {ok, Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Host">>, self()),
    {P2, T2, undefined} = stw_lobby:hello(undefined, <<"Crew">>),
    {ok, GamePid} = stw_lobby:join_room(T2, Room),
    Sock = spawn(fun() -> receive stop -> ok end end),
    {ok, false} = stw_game:join(GamePid, P2, <<"Crew">>, Sock),
    flush(),
    %% kill P2's socket and wait for the game to observe the DOWN
    MRef = monitor(process, Sock),
    Sock ! stop,
    receive {'DOWN', MRef, _, _, _} -> ok after 1000 -> erlang:error(no_down) end,
    L1 = expect_push(<<"lobby_state">>),
    ?assertEqual(false, connected(P2, L1)),
    %% P2 is still a member and can resume
    ok = stw_game:reconnect(GamePid, P2, self()),
    L2 = expect_push(<<"lobby_state">>),
    ?assertEqual(true, connected(P2, L2)).

%% --- timeout robustness -----------------------------------------------

%% A ping_timeout that arrives while still in the lobby (or otherwise with
%% nothing to auto-fill) is a harmless no-op, not a crash or a phantom round.
stale_timeout_is_safe() ->
    flush(),
    {GamePid, _Players} = lobby_game(1),
    GamePid ! ping_timeout,
    timer:sleep(20),
    ?assert(is_process_alive(GamePid)),
    ?assertEqual(no_message, peek(<<"round_result">>)).

%% When the timer fires, a player who programmed but did not lock keeps that
%% program; only players with no program at all are auto-filled.
timeout_preserves_partial() ->
    flush(),
    {GamePid, [P1, P2]} = started_game(1),
    Prog = draft_nav(deal_for(P1)),
    _ = deal_for(P2),
    %% P1 programs but never locks; P2 does nothing
    ok = stw_game:program_registers(GamePid, P1, Prog),
    GamePid ! ping_timeout,
    Res = expect_push(<<"registers_resolving">>),
    ?assertEqual([P2], maps:get(<<"auto_filled">>, Res)),
    RR = expect_push(<<"round_result">>),
    ?assertEqual(5, length(maps:get(<<"phases">>, RR))).

%% --- server authority (anti-cheat) ------------------------------------

only_host_starts() ->
    flush(),
    {GamePid, [_Host, Crew]} = lobby_game(1),
    ?assertEqual({error, not_host}, stw_game:start_game(GamePid, Crew)).
host_cannot_restart() ->
    flush(),
    {GamePid, [Host, Crew]} = started_game(1),
    ?assertEqual({error, not_lobby}, stw_game:start_game(GamePid, Host)),
    ?assertEqual({error, not_host}, stw_game:start_game(GamePid, Crew)).


no_act_before_start() ->
    flush(),
    {GamePid, [P1 | _]} = lobby_game(1),
    ?assertEqual({error, not_in_game},
                 stw_game:program_registers(GamePid, P1, [])),
    ?assertEqual({error, not_in_game}, stw_game:lock_registers(GamePid, P1)).

%% Programs are validated against the player's own dealt hand: too many
%% cards, duplicates, and ids that were never dealt are all rejected, so a
%% client cannot smuggle in cards it does not hold.
rejects_bad_programs() ->
    flush(),
    {GamePid, [P1, _P2]} = started_game(1),
    Ids = hand_ids(deal_for(P1)),
    ?assert(length(Ids) >= 6),
    ?assertEqual({error, invalid_register},
                 stw_game:program_registers(GamePid, P1, lists:sublist(Ids, 6))),
    [A | _] = Ids,
    ?assertEqual({error, invalid_register},
                 stw_game:program_registers(GamePid, P1, [A, A])),
    ?assertEqual({error, invalid_register},
                 stw_game:program_registers(GamePid, P1,
                                            [<<"forged-1">>, <<"forged-2">>])),
    %% a legitimate 5-card program from the real hand is accepted
    ?assertEqual(ok,
                 stw_game:program_registers(GamePid, P1, lists:sublist(Ids, 5))).
locked_program_cannot_change() ->
    flush(),
    {GamePid, [P1 | _]} = started_game(1),
    Ids = hand_ids(deal_for(P1)),
    Original = lists:sublist(Ids, 5),
    Replacement = lists:sublist(lists:nthtail(1, Ids), 5),
    ok = stw_game:program_registers(GamePid, P1, Original),
    ok = stw_game:lock_registers(GamePid, P1),
    ?assertEqual({error, already_locked},
                 stw_game:program_registers(GamePid, P1, Replacement)).

%% A player who is not seated in a match cannot program it.
outsider_cannot_program() ->
    flush(),
    {GamePid, _Players} = started_game(1),
    {Ghost, _T, _} = stw_lobby:hello(undefined, <<"Ghost">>),
    ?assertEqual({error, not_in_game},
                 stw_game:program_registers(GamePid, Ghost, [])),
    ?assertEqual({error, not_in_game}, stw_game:lock_registers(GamePid, Ghost)).

no_lock_without_program() ->
    flush(),
    {GamePid, [P1, _P2]} = started_game(1),
    _ = deal_for(P1),
    ?assertEqual({error, no_program}, stw_game:lock_registers(GamePid, P1)).

%% --- room / player helpers --------------------------------------------

%% Create a room with a host plus NCrew additional players (all on self()),
%% still in the lobby. Returns {GamePid, [HostId | CrewIds]}.
lobby_game(NCrew) ->
    {P1, T1, undefined} = stw_lobby:hello(undefined, <<"Host">>),
    {ok, Room, GamePid} = stw_lobby:create_game(T1, #{}),
    {ok, true} = stw_game:join(GamePid, P1, <<"Host">>, self()),
    Crew = [add_crew(GamePid, Room) || _ <- lists:seq(1, NCrew)],
    {GamePid, [P1 | Crew]}.

add_crew(GamePid, Room) ->
    {P, T, undefined} = stw_lobby:hello(undefined, <<"Crew">>),
    {ok, GamePid} = stw_lobby:join_room(T, Room),
    {ok, false} = stw_game:join(GamePid, P, <<"Crew">>, self()),
    P.

%% Like lobby_game/1 but the host has started the match. Note: no flush here
%% so back-to-back games keep each other's pending deals intact; deal_for/1
%% is selective, so leftover lobby noise never interferes.
started_game(NCrew) ->
    {GamePid, [Host | _] = Players} = lobby_game(NCrew),
    ok = stw_game:start_game(GamePid, Host),
    {GamePid, Players}.

%% Draft up to 5 navigation cards (combat-free) from a dealt hand, consuming
%% the deal so later selective receives see the next round.
draft_nav(Deal) ->
    Cards = maps:get(<<"cards">>, Deal),
    Ids = [maps:get(<<"id">>, C) || C <- Cards,
                                    lists:member(maps:get(<<"kind">>, C), ?NAV)],
    lists:sublist(Ids, 5).

hand_ids(Deal) ->
    [maps:get(<<"id">>, C) || C <- maps:get(<<"cards">>, Deal)].

%% Draft, program and lock every player so the round resolves.
play_round(GamePid, Players) ->
    Progs = [{P, draft_nav(deal_for(P))} || P <- Players],
    [ok = stw_game:program_registers(GamePid, P, Prog) || {P, Prog} <- Progs],
    [ok = stw_game:lock_registers(GamePid, P) || {P, _} <- Progs],
    ok.

%% Resolve a round with stationary hold programs (no draft needed), so the
%% match never mutates state and can be driven deterministically under load.
play_holds(GamePid, Players) ->
    [ok = stw_game:program_registers(GamePid, P, []) || P <- Players],
    [ok = stw_game:lock_registers(GamePid, P) || P <- Players],
    ok.

connected(PlayerId, Lobby) ->
    Players = maps:get(<<"players">>, Lobby),
    case [P || P <- Players, maps:get(<<"player_id">>, P) =:= PlayerId] of
        [P] -> maps:get(<<"connected">>, P);
        [] -> undefined
    end.

%% --- mailbox helpers --------------------------------------------------

expect_push(Type) ->
    receive
        {push, Type, Payload} -> Payload
    after 1000 ->
        erlang:error({timeout_waiting_for, Type})
    end.

%% Non-blocking check that a push of Type is NOT present within a short grace.
peek(Type) ->
    receive
        {push, Type, Payload} -> Payload
    after 100 ->
        no_message
    end.

%% Selectively receive the private deal_hand for a specific player.
deal_for(PlayerId) ->
    receive
        {push, <<"deal_hand">>, #{<<"player_id">> := PlayerId} = Payload} ->
            Payload
    after 1000 ->
        erlang:error({timeout_deal, PlayerId})
    end.

has_hand(PlayerId) ->
    is_map(deal_for(PlayerId)).

flush() ->
    receive _ -> flush() after 0 -> ok end.
