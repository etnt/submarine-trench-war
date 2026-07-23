%%%-------------------------------------------------------------------
%% @doc Deterministic movement / phase resolution engine (pure).
%%
%% Given the board, the current submarines, and each player's 5-card
%% program, `resolve_round/3` plays out the round one register at a time
%% and returns the final submarine state plus an ordered list of per-phase
%% snapshots for the client to animate.
%%
%% The engine has no side effects and no randomness, so the same inputs
%% always produce the same output. Combat is out of scope for this phase;
%% here movement only has to respect walls, the board edge, other subs
%% (no overlaps, no passing through each other), and currents.
%%
%% Submarines are plain maps with atom keys: `#{x, y, facing, depth, ...}`.
%% `facing` and `depth` are binaries (`<<"N">>`, `<<"shallow">>`, ...) to
%% match the wire format. Programs map player_id => list of 5 card kinds
%% (binaries); a missing or short program is treated as holds.
%% @end
%%%-------------------------------------------------------------------
-module(stw_engine).

-export([resolve_round/3, card_kinds/0, valid_card/1]).

-define(REGISTERS, 5).

-type sub() :: map().
-type subs() :: #{binary() => sub()}.
-type programs() :: #{binary() => [binary()]}.

%% --- public -----------------------------------------------------------

%% @doc The navigation card kinds available in this phase.
-spec card_kinds() -> [binary()].
card_kinds() ->
    [<<"ahead_standard">>, <<"ahead_flank">>, <<"reverse">>,
     <<"port_bank">>, <<"starboard_bank">>, <<"dive">>, <<"surface">>].

-spec valid_card(binary()) -> boolean().
valid_card(Kind) ->
    lists:member(Kind, card_kinds()).

%% @doc Play out one round (5 registers). Returns `{FinalSubs, Phases}`
%% where each phase is a map with the register index, a submarine snapshot,
%% and a list of events.
-spec resolve_round(stw_board:board(), subs(), programs()) ->
    {subs(), [map()]}.
resolve_round(Board, Subs, Programs) ->
    {Final, Rev} =
        lists:foldl(
          fun(R, {S, Acc}) ->
              {S1, Ev1} = apply_register(Board, S, Programs, R),
              {S2, Ev2} = apply_currents(Board, S1),
              Phase = #{<<"register">> => R,
                        <<"submarines">> => snapshot(S2),
                        <<"events">> => Ev1 ++ Ev2},
              {S2, [Phase | Acc]}
          end,
          {Subs, []},
          lists:seq(0, ?REGISTERS - 1)),
    {Final, lists:reverse(Rev)}.

%% --- one register -----------------------------------------------------

apply_register(Board, Subs, Programs, R) ->
    %% Rotations and depth changes apply first and cannot conflict.
    {Subs1, RotEvents} = apply_turns(Subs, Programs, R),
    Movers = build_movers(Subs1, Programs, R),
    {Subs2, MoveEvents} = step_movers(Board, Subs1, Movers),
    {Subs2, RotEvents ++ MoveEvents}.

apply_turns(Subs, Programs, R) ->
    lists:foldl(
      fun(Id, {Acc, Evs}) ->
          Sub = maps:get(Id, Acc),
          case action(card_at(Programs, Id, R)) of
              {rotate, Turn} ->
                  F = rotate(maps:get(facing, Sub), Turn),
                  {maps:put(Id, Sub#{facing => F}, Acc),
                   Evs ++ [event(<<"rotate">>, Id, #{<<"facing">> => F})]};
              {depth, D} ->
                  {maps:put(Id, Sub#{depth => D}, Acc),
                   Evs ++ [event(depth_event(D), Id, #{})]};
              _ ->
                  {Acc, Evs}
          end
      end,
      {Subs, []},
      lists:sort(maps:keys(Subs))).

%% Build {Id, Dir, Steps} tuples for the subs whose card is a move.
build_movers(Subs, Programs, R) ->
    lists:filtermap(
      fun(Id) ->
          Sub = maps:get(Id, Subs),
          Facing = maps:get(facing, Sub),
          case action(card_at(Programs, Id, R)) of
              {move, forward, N} -> {true, {Id, dir_vec(Facing), N}};
              {move, backward, N} -> {true, {Id, neg(dir_vec(Facing)), N}};
              _ -> false
          end
      end,
      lists:sort(maps:keys(Subs))).

%% --- movement resolution ----------------------------------------------

%% Resolve a set of movers one unit step at a time until none remain.
step_movers(_Board, Subs, []) ->
    {Subs, []};
step_movers(Board, Subs, Movers) ->
    step_loop(Board, Subs, Movers, []).

step_loop(_Board, Subs, [], Evs) ->
    {Subs, Evs};
step_loop(Board, Subs, Movers, Evs) ->
    {Subs1, StepEvs, Next} = unit_step(Board, Subs, Movers),
    step_loop(Board, Subs1, Next, Evs ++ StepEvs).

%% A single simultaneous unit step. Returns the new subs, any events, and
%% the movers that still have steps left (successful movers with remaining
%% distance). Blocked movers are dropped and stop for the register.
unit_step(Board, Subs, Movers) ->
    Detailed = [{Id, Dir, Steps, pos(Subs, Id), add(pos(Subs, Id), Dir)}
                || {Id, Dir, Steps} <- Movers],
    %% 1. walls / edge
    {Valid, Blocked0} =
        lists:partition(fun({_, _, _, _, T}) -> passable(Board, T) end, Detailed),
    %% 2. two movers wanting the same tile -> both blocked
    Counts = tally([T || {_, _, _, _, T} <- Valid]),
    {Contended, Uncon} =
        lists:partition(fun({_, _, _, _, T}) -> maps:get(T, Counts) > 1 end, Valid),
    %% 3. two movers swapping tiles -> both blocked (no passing through)
    {Swapped, Clean} =
        lists:partition(fun(M) -> is_swap(M, Uncon) end, Uncon),
    %% 4. can't move onto a tile a non-moving (or blocked) sub keeps
    Success = settle(Clean, Subs),
    Demoted = Clean -- Success,
    Blocked = Blocked0 ++ Contended ++ Swapped ++ Demoted,

    Subs1 = lists:foldl(
              fun({Id, _Dir, _Steps, _From, {X, Y}}, Acc) ->
                  S = maps:get(Id, Acc),
                  maps:put(Id, S#{x => X, y => Y}, Acc)
              end, Subs, Success),
    Evs = [event(<<"blocked">>, Id, #{}) || {Id, _, _, _, _} <- Blocked],
    Next = [{Id, Dir, Steps - 1}
            || {Id, Dir, Steps, _F, _T} <- Success, Steps - 1 > 0],
    {Subs1, Evs, Next}.

%% Fixed point: a candidate can only advance onto a tile that will be empty.
%% A tile stays occupied if a non-moving sub sits on it, or a candidate that
%% got demoted stays put — which may in turn demote its followers.
settle(Cands, Subs) ->
    CandIds = [Id || {Id, _, _, _, _} <- Cands],
    NonMovers = lists:sort(maps:keys(Subs)) -- CandIds,
    StayPos = sets:from_list([pos(Subs, Id) || Id <- NonMovers]),
    settle_loop(Cands, StayPos).

settle_loop(Cands, StayPos) ->
    {Ok, Demoted} =
        lists:partition(
          fun({_, _, _, _, T}) -> not sets:is_element(T, StayPos) end, Cands),
    case Demoted of
        [] ->
            Ok;
        _ ->
            StayPos1 = lists:foldl(
                         fun({_, _, _, From, _}, Acc) -> sets:add_element(From, Acc) end,
                         StayPos, Demoted),
            settle_loop(Ok, StayPos1)
    end.

is_swap({_Id, _Dir, _Steps, From, To}, Movers) ->
    lists:any(
      fun({_, _, _, F2, T2}) -> F2 =:= To andalso T2 =:= From end, Movers).

%% --- currents ---------------------------------------------------------

%% After a register resolves, spin subs on turbulence and drift subs on
%% currents. Turbulence is a pure rotation; drift reuses the movement
%% resolver so it respects walls and other subs.
apply_currents(Board, Subs) ->
    {Subs1, TurbEvents} = apply_turbulence(Board, Subs),
    Drifters = [{Id, dir_vec(dir_bin(Dir)), Str}
                || Id <- lists:sort(maps:keys(Subs1)),
                   {Dir, Str} <- [stw_board:current_at(Board, pos(Subs1, Id))],
                   Dir =/= none],
    {Subs2, MoveEvents} = step_movers(Board, Subs1, Drifters),
    DriftEvents = [event(<<"drift">>, Id, #{}) || {Id, _, _} <- Drifters],
    {Subs2, TurbEvents ++ DriftEvents ++ MoveEvents}.

apply_turbulence(Board, Subs) ->
    lists:foldl(
      fun(Id, {Acc, Evs}) ->
          Sub = maps:get(Id, Acc),
          case stw_board:turbulence_at(Board, pos(Acc, Id)) of
              true ->
                  F = rotate(maps:get(facing, Sub), right),
                  {maps:put(Id, Sub#{facing => F}, Acc),
                   Evs ++ [event(<<"turbulence">>, Id, #{<<"facing">> => F})]};
              false ->
                  {Acc, Evs}
          end
      end,
      {Subs, []},
      lists:sort(maps:keys(Subs))).

%% --- cards ------------------------------------------------------------

card_at(Programs, Id, R) ->
    case maps:find(Id, Programs) of
        {ok, Cards} when length(Cards) > R -> lists:nth(R + 1, Cards);
        _ -> undefined
    end.

action(<<"ahead_standard">>) -> {move, forward, 1};
action(<<"ahead_flank">>) -> {move, forward, 2};
action(<<"reverse">>) -> {move, backward, 1};
action(<<"port_bank">>) -> {rotate, left};
action(<<"starboard_bank">>) -> {rotate, right};
action(<<"dive">>) -> {depth, <<"deep">>};
action(<<"surface">>) -> {depth, <<"shallow">>};
action(_) -> hold.

depth_event(<<"deep">>) -> <<"dive">>;
depth_event(<<"shallow">>) -> <<"surface">>.

%% --- geometry ---------------------------------------------------------

dir_vec(<<"N">>) -> {0, -1};
dir_vec(<<"E">>) -> {1, 0};
dir_vec(<<"S">>) -> {0, 1};
dir_vec(<<"W">>) -> {-1, 0}.

dir_bin(n) -> <<"N">>;
dir_bin(e) -> <<"E">>;
dir_bin(s) -> <<"S">>;
dir_bin(w) -> <<"W">>;
dir_bin(none) -> none.

rotate(<<"N">>, left) -> <<"W">>;
rotate(<<"W">>, left) -> <<"S">>;
rotate(<<"S">>, left) -> <<"E">>;
rotate(<<"E">>, left) -> <<"N">>;
rotate(<<"N">>, right) -> <<"E">>;
rotate(<<"E">>, right) -> <<"S">>;
rotate(<<"S">>, right) -> <<"W">>;
rotate(<<"W">>, right) -> <<"N">>.

neg({X, Y}) -> {-X, -Y}.
add({X, Y}, {Dx, Dy}) -> {X + Dx, Y + Dy}.

pos(Subs, Id) ->
    S = maps:get(Id, Subs),
    {maps:get(x, S), maps:get(y, S)}.

passable(Board, Coord) ->
    stw_board:tile_at(Board, Coord) =/= wall.

%% --- misc -------------------------------------------------------------

tally(List) ->
    lists:foldl(fun(K, Acc) -> maps:update_with(K, fun(V) -> V + 1 end, 1, Acc) end,
                #{}, List).

event(Type, Id, Extra) ->
    Extra#{<<"type">> => Type, <<"player_id">> => Id}.

snapshot(Subs) ->
    [begin
         S = maps:get(Id, Subs),
         #{<<"player_id">> => Id,
           <<"x">> => maps:get(x, S),
           <<"y">> => maps:get(y, S),
           <<"facing">> => maps:get(facing, S),
           <<"depth">> => maps:get(depth, S)}
     end || Id <- lists:sort(maps:keys(Subs))].
