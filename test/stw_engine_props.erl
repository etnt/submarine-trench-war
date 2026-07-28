%%%-------------------------------------------------------------------
%% @doc Phase 11 hardening: seeded-scenario and property-style tests for
%% the pure resolution engine.
%%
%% Rather than pull in an external property-testing framework (which would
%% add a build dependency), these tests generate many randomised scenarios
%% from a *fixed* seed and assert that structural invariants hold for every
%% one. Because the engine is a pure function of (board, subs, programs),
%% seeding `rand` makes the whole sweep reproducible: a failure always
%% reproduces on the next run, and we can print the offending scenario.
%%
%% Invariants checked across every register snapshot and the final state:
%%   * determinism   - resolving the same inputs twice is byte-identical
%%   * five phases    - a round always yields exactly 5 register snapshots
%%   * roster kept    - every submarine appears in every snapshot
%%   * in bounds      - an alive sub is never on a wall or off the board
%%   * legal facing   - facing is always one of N/E/S/W
%%   * hull sane      - hull never rises, never exceeds the start hull, and a
%%                      sub is marked dead once its hull is gone
%%   * no resurrection- alive never flips false -> true
%%   * no overlap     - two alive subs never share the same tile + depth
%% @end
%%%-------------------------------------------------------------------
-module(stw_engine_props).

-include_lib("eunit/include/eunit.hrl").

-define(SCENARIOS, 400).
-define(START_HULL, 10).

%% --- board fixtures ---------------------------------------------------

%% An open room bordered by wall, matching stw_engine_tests:open_board/2.
open_board(W, H) ->
    Tiles = maps:from_list(
              [{{X, Y}, border(X, Y, W, H)}
               || X <- lists:seq(0, W - 1), Y <- lists:seq(0, H - 1)]),
    #{width => W, height => H, tiles => Tiles,
      spawns => [], data_nodes => [], extraction => {0, 0},
      currents => #{}, turbulence => []}.

border(X, Y, W, H) when X =:= 0; Y =:= 0; X =:= W - 1; Y =:= H - 1 -> wall;
border(_, _, _, _) -> trench.

%% A busier board: interior wall pillars, a current, turbulence, a mine and
%% a vent, so scenarios exercise every movement/hazard branch.
busy_board(W, H) ->
    B0 = open_board(W, H),
    T0 = maps:get(tiles, B0),
    T1 = lists:foldl(fun(C, Acc) -> maps:put(C, wall, Acc) end, T0,
                     [{4, 3}, {5, 3}, {8, 5}]),
    T2 = maps:put({6, 6}, mine, T1),
    T3 = maps:put({3, 6}, vent, T2),
    B0#{tiles => T3,
        currents => #{{7, 2} => {e, 1}},
        turbulence => [{9, 4}]}.

%% --- seeded property sweep --------------------------------------------

invariants_hold_over_random_scenarios_test_() ->
    {timeout, 60, fun() ->
        run_sweep(fun open_board/2),
        run_sweep(fun busy_board/2)
    end}.

run_sweep(BoardFun) ->
    lists:foreach(
      fun(Seed) ->
          rand:seed(exsss, {Seed, Seed * 7 + 1, Seed * 13 + 3}),
          Scenario = gen_scenario(BoardFun),
          check_scenario(Scenario)
      end,
      lists:seq(1, ?SCENARIOS)).

%% Build a random but legal scenario: 2-4 subs on distinct open tiles, each
%% programmed with 5 random cards from the full deck.
gen_scenario(BoardFun) ->
    W = 12, H = 8,
    Board = BoardFun(W, H),
    NumSubs = 2 + rand:uniform(3) - 1,      % 2..4
    Positions = distinct_positions(Board, NumSubs),
    Ids = [list_to_binary([$s, $0 + I]) || I <- lists:seq(1, NumSubs)],
    Cards = stw_engine:card_kinds(),
    Subs = maps:from_list(
             [{Id, rand_sub(Pos)} || {Id, Pos} <- lists:zip(Ids, Positions)]),
    Programs = maps:from_list(
                 [{Id, [rand_card(Cards) || _ <- lists:seq(1, 5)]} || Id <- Ids]),
    #{board => Board, subs => Subs, programs => Programs}.

rand_sub({X, Y}) ->
    #{x => X, y => Y,
      facing => rand_elem([<<"N">>, <<"E">>, <<"S">>, <<"W">>]),
      depth => rand_elem([<<"shallow">>, <<"deep">>]),
      hull => ?START_HULL, alive => true, data => 0}.

rand_card(Cards) -> rand_elem(Cards).

rand_elem(L) -> lists:nth(rand:uniform(length(L)), L).

%% Pick N distinct open (trench/mine/vent, never wall) interior tiles.
distinct_positions(Board, N) ->
    Open = [C || {C, K} <- maps:to_list(maps:get(tiles, Board)), K =/= wall],
    take_distinct(shuffle(Open), N).

take_distinct(_, 0) -> [];
take_distinct([H | T], N) -> [H | take_distinct(T, N - 1)].

shuffle(L) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- L])].

%% --- invariant checks -------------------------------------------------

check_scenario(#{board := B, subs := Subs, programs := P} = Sc) ->
    R1 = stw_engine:resolve_round(B, Subs, P),
    R2 = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(R1, R2),                       % determinism
    {Final, Phases, _Effects} = R1,
    ckeq(5, length(Phases), Sc, "expected 5 phases"),
    Ids = maps:keys(Subs),
    lists:foreach(fun(Ph) -> check_phase(Sc, B, Ids, Ph) end, Phases),
    check_final(Sc, B, Ids, Subs, Final),
    check_hull_monotonic(Sc, Subs, Phases).

check_phase(Sc, B, Ids, Ph) ->
    Snap = maps:get(<<"submarines">>, Ph),
    SnapIds = [maps:get(<<"player_id">>, M) || M <- Snap],
    ckeq(lists:sort(Ids), lists:sort(SnapIds), Sc, "snapshot dropped a sub"),
    Alive = [M || M <- Snap, maps:get(<<"alive">>, M)],
    [check_alive_member(Sc, B, M) || M <- Alive],
    assert_no_overlap(Sc, Alive).

check_alive_member(Sc, B, M) ->
    X = maps:get(<<"x">>, M),
    Y = maps:get(<<"y">>, M),
    ckne(wall, stw_board_tile(B, X, Y), Sc, "alive sub on a wall tile"),
    ck(in_bounds(B, X, Y), Sc, "alive sub out of bounds"),
    ck(lists:member(maps:get(<<"facing">>, M),
                    [<<"N">>, <<"E">>, <<"S">>, <<"W">>]),
       Sc, "illegal facing"),
    Hull = maps:get(<<"hull">>, M),
    ck(Hull =< ?START_HULL, Sc, "hull exceeded start").

check_final(Sc, B, Ids, Subs0, Final) ->
    ckeq(lists:sort(Ids), lists:sort(maps:keys(Final)), Sc,
         "final state dropped a submarine"),
    maps:foreach(
      fun(Id, F) ->
          Hull = maps:get(hull, F),
          Alive = maps:get(alive, F),
          Start = maps:get(hull, maps:get(Id, Subs0)),
          ck(Hull =< Start, Sc, "final hull rose"),
          %% a sub with no hull left must be dead; a live sub must have hull
          case Hull =< 0 of
              true -> ckeq(false, Alive, Sc, "0-hull sub still alive");
              false -> ok
          end,
          case Alive of
              true ->
                  X = maps:get(x, F), Y = maps:get(y, F),
                  ckne(wall, stw_board_tile(B, X, Y), Sc,
                       "final alive sub on wall"),
                  ck(in_bounds(B, X, Y), Sc,
                     "final alive sub out of bounds");
              false -> ok
          end
      end, Final).

%% Hull is monotonic non-increasing register-to-register, and once a sub is
%% dead in a snapshot it never reappears alive.
check_hull_monotonic(Sc, Subs0, Phases) ->
    Ids = maps:keys(Subs0),
    lists:foreach(
      fun(Id) ->
          Start = maps:get(hull, maps:get(Id, Subs0)),
          Series = [snap_field(Ph, Id, <<"hull">>) || Ph <- Phases],
          AliveS = [snap_field(Ph, Id, <<"alive">>) || Ph <- Phases],
          assert_non_increasing(Sc, [Start | Series]),
          assert_no_resurrection(Sc, AliveS)
      end, Ids).

assert_non_increasing(_Sc, [_]) -> ok;
assert_non_increasing(Sc, [A, B | T]) ->
    ck(B =< A, Sc, "hull rose between registers"),
    assert_non_increasing(Sc, [B | T]).

assert_no_resurrection(_Sc, []) -> ok;
assert_no_resurrection(Sc, [false | T]) ->
    ck(lists:all(fun(A) -> A =:= false end, T), Sc,
       "dead sub came back to life"),
    ok;
assert_no_resurrection(Sc, [true | T]) ->
    assert_no_resurrection(Sc, T).

%% No two alive subs occupy the same tile at the same depth.
assert_no_overlap(Sc, Alive) ->
    Cells = [{maps:get(<<"x">>, M), maps:get(<<"y">>, M),
              maps:get(<<"depth">>, M)} || M <- Alive],
    ckeq(length(Cells), length(lists:usort(Cells)), Sc,
         "two alive subs share a tile + depth").

%% --- assertion helpers with scenario context -------------------------
%%
%% EUnit's assert macros do not carry a custom message, so these wrap the
%% predicate and raise with the offending scenario rendered for debugging.

ck(true, _Sc, _Msg) -> ok;
ck(false, Sc, Msg) -> erlang:error({property_failed, fail(Sc, Msg)}).

ckeq(X, X, _Sc, _Msg) -> ok;
ckeq(A, B, Sc, Msg) ->
    erlang:error({property_failed, fail(Sc, Msg), {expected, A}, {got, B}}).

ckne(X, X, Sc, Msg) ->
    erlang:error({property_failed, fail(Sc, Msg), {unexpected, X}});
ckne(_, _, _Sc, _Msg) -> ok.

%% --- small helpers ----------------------------------------------------

snap_field(Ph, Id, Field) ->
    Snap = maps:get(<<"submarines">>, Ph),
    M = hd([X || X <- Snap, maps:get(<<"player_id">>, X) =:= Id]),
    maps:get(Field, M).

stw_board_tile(B, X, Y) ->
    maps:get({X, Y}, maps:get(tiles, B), wall).

in_bounds(B, X, Y) ->
    X >= 0 andalso Y >= 0 andalso
    X < maps:get(width, B) andalso Y < maps:get(height, B).

%% Render a failing scenario compactly for the assertion message.
fail(#{subs := Subs, programs := P}, Msg) ->
    lists:flatten(io_lib:format("~s | subs=~p programs=~p", [Msg, Subs, P])).

%% --- explicit seeded golden scenarios ---------------------------------
%%
%% A hand-authored multi-mechanic round whose exact outcome is pinned, so a
%% regression in any single interaction (movement + current + mine + combat)
%% is caught with a precise, readable expectation.

golden_combined_scenario_test() ->
    B = busy_board(12, 8),
    Subs = #{<<"a">> => sub(2, 2, <<"E">>),
             <<"b">> => sub(10, 5, <<"E">>)},
    %% a: standard, standard, standard, hold, hold  -> drifts on the current
    %% b: reverse, hold, hold, hold, hold
    P = #{<<"a">> => [<<"ahead_standard">>, <<"ahead_standard">>,
                      <<"ahead_standard">>, <<"hold">>, <<"hold">>],
          <<"b">> => [<<"reverse">>, <<"hold">>, <<"hold">>,
                      <<"hold">>, <<"hold">>]},
    R1 = stw_engine:resolve_round(B, Subs, P),
    R2 = stw_engine:resolve_round(B, Subs, P),
    ?assertEqual(R1, R2),
    {Final, Phases, _} = R1,
    ?assertEqual(5, length(Phases)),
    %% a starts at (2,2) heading east: reg0 -> (3,2), reg1 -> (4,2)? (4,3) is
    %% wall but (4,2) is open, reg2 -> (5,2). It never touches a hazard here,
    %% so it survives at full hull.
    ?assertEqual(10, maps:get(hull, maps:get(<<"a">>, Final))),
    ?assertEqual(true, maps:get(alive, maps:get(<<"a">>, Final))),
    %% b reverses west one tile from (10,5) to (9,5) then holds.
    ?assertEqual({9, 5},
                 {maps:get(x, maps:get(<<"b">>, Final)),
                  maps:get(y, maps:get(<<"b">>, Final))}).

sub(X, Y, Facing) ->
    #{x => X, y => Y, facing => Facing, depth => <<"shallow">>,
      hull => ?START_HULL, alive => true, data => 0}.
