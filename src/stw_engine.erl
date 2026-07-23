%%%-------------------------------------------------------------------
%% @doc Deterministic movement / phase resolution engine (pure).
%%
%% Given the board, the current submarines, and each player's 5-card
%% program, `resolve_round/3` plays out the round one register at a time
%% and returns the final submarine state, an ordered list of per-phase
%% snapshots for the client to animate, and a small effects map (e.g. the
%% mines that were consumed this round).
%%
%% The engine has no side effects and no randomness, so the same inputs
%% always produce the same output.
%%
%% Per register the pipeline is:
%%   1. detonate depth charges armed on the previous register (1-phase delay)
%%   2. rotations and depth changes
%%   3. weapons: torpedoes and sonar pings (hit-scan), arm depth charges
%%   4. movement (walls, edges, other subs, ramming collisions)
%%   5. currents (turbulence rotation + drift)
%%   6. mines (enter a mine tile: damage, scramble a later register, consume)
%%   7. thermal vents (a Deep sub on a vent is forced to Shallow)
%%   8. destruction (hull <= 0 marks the sub as a wreck)
%%
%% Submarines are plain maps with atom keys:
%%   `#{x, y, facing, depth, hull, data, alive}`.
%% `facing` and `depth` are binaries (`<<"N">>`, `<<"shallow">>`, ...) to
%% match the wire format. Programs map player_id => list of 5 card kinds
%% (binaries); a missing or short program is treated as holds. Dead subs
%% stay in the map (as wrecks that still block movement) but take no action.
%% @end
%%%-------------------------------------------------------------------
-module(stw_engine).

-export([resolve_round/3, card_kinds/0, nav_cards/0, tactical_cards/0,
         valid_card/1]).

-define(REGISTERS, 5).

%% Damage each weapon / hazard deals.
-define(DMG_TORPEDO, 2).
-define(DMG_DEPTH_CHARGE, 3).
-define(DMG_SONAR, 1).
-define(DMG_MINE, 3).
-define(DMG_RAM, 1).

-type sub() :: map().
-type subs() :: #{binary() => sub()}.
-type programs() :: #{binary() => [binary()]}.

%% --- public -----------------------------------------------------------

%% @doc Navigation cards: the movement half of the deck.
-spec nav_cards() -> [binary()].
nav_cards() ->
    [<<"ahead_standard">>, <<"ahead_flank">>, <<"reverse">>,
     <<"port_bank">>, <<"starboard_bank">>, <<"dive">>, <<"surface">>].

%% @doc Tactical cards: the combat half of the deck.
-spec tactical_cards() -> [binary()].
tactical_cards() ->
    [<<"torpedo">>, <<"depth_charge">>, <<"sonar_ping">>].

%% @doc Every card kind the engine understands.
-spec card_kinds() -> [binary()].
card_kinds() ->
    nav_cards() ++ tactical_cards().

-spec valid_card(binary()) -> boolean().
valid_card(Kind) ->
    lists:member(Kind, card_kinds()).

%% @doc Play out one round (5 registers). Returns
%% `{FinalSubs, Phases, Effects}` where each phase is a map with the
%% register index, a submarine snapshot, and a list of events, and Effects
%% is `#{mines_cleared => [{X, Y}]}`.
-spec resolve_round(stw_board:board(), subs(), programs()) ->
    {subs(), [map()], map()}.
resolve_round(Board, Subs0, Programs0) ->
    St0 = #{subs => ensure_fields(Subs0),
            programs => Programs0,
            armed => [],
            cleared => []},
    {StN, Rev} =
        lists:foldl(
          fun(R, {St, Acc}) ->
              {St1, Events} = apply_register(Board, St, R),
              Phase = #{<<"register">> => R,
                        <<"submarines">> => snapshot(maps:get(subs, St1)),
                        <<"events">> => Events},
              {St1, [Phase | Acc]}
          end,
          {St0, []},
          lists:seq(0, ?REGISTERS - 1)),
    {StF, Phases} = final_detonate(Board, StN, lists:reverse(Rev)),
    Effects = #{mines_cleared => lists:usort(maps:get(cleared, StF))},
    {maps:get(subs, StF), Phases, Effects}.

%% --- one register -----------------------------------------------------

apply_register(Board, St, R) ->
    Subs0 = maps:get(subs, St),
    Programs = maps:get(programs, St),
    ArmedPrev = maps:get(armed, St),
    Cleared0 = maps:get(cleared, St),
    %% 1. depth charges armed last register go off now (1-phase delay)
    {Subs1, E1} = detonate(Subs0, ArmedPrev),
    %% 2. rotations + depth changes
    {Subs2, E2} = apply_turns(Subs1, Programs, R),
    %% 3. weapons + arming
    {Subs3, E3, ArmedNow} = apply_fires(Board, Subs2, Programs, R),
    %% 4. movement (with ramming)
    Movers = build_movers(Subs3, Programs, R),
    {Subs4, E4} = step_movers(Board, Subs3, Movers, true),
    %% 5. currents
    {Subs5, E5} = apply_currents(Board, Subs4),
    %% 6. mines
    {Subs6, E6, Programs1, Cleared1} =
        apply_mines(Board, Subs5, Programs, R, Cleared0),
    %% 7. thermal vents
    {Subs7, E7} = apply_vents(Board, Subs6),
    %% 8. destruction
    {Subs8, E8} = reap(Subs7),
    St1 = St#{subs => Subs8, programs => Programs1,
              armed => ArmedNow, cleared => Cleared1},
    {St1, E1 ++ E2 ++ E3 ++ E4 ++ E5 ++ E6 ++ E7 ++ E8}.

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
      alive_ids(Subs)).

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
      alive_ids(Subs)).

%% --- weapons ----------------------------------------------------------

%% Fire torpedoes and sonar pings, and arm depth charges. Weapons use the
%% positions after turns; damage is applied immediately (hit-scan).
apply_fires(Board, Subs, Programs, R) ->
    lists:foldl(
      fun(Id, {S, Evs, Armed}) ->
          case action(card_at(Programs, Id, R)) of
              {fire, torpedo} ->
                  {S1, Ev} = fire_beam(Board, S, Id, <<"torpedo">>, ?DMG_TORPEDO, true),
                  {S1, Evs ++ Ev, Armed};
              {fire, sonar} ->
                  {S1, Ev} = fire_beam(Board, S, Id, <<"sonar_ping">>, ?DMG_SONAR, false),
                  {S1, Evs ++ Ev, Armed};
              {arm, depth_charge} ->
                  {X, Y} = pos(S, Id),
                  {S, Evs ++ [event(<<"depth_charge_armed">>, Id,
                                    #{<<"x">> => X, <<"y">> => Y})],
                   Armed ++ [#{owner => Id, x => X, y => Y}]};
              _ ->
                  {S, Evs, Armed}
          end
      end,
      {Subs, [], []},
      alive_ids(Subs)).

%% A straight beam (torpedo or sonar) from the sub along its facing. Depth
%% gates whether a same-tile enemy can be hit. Returns updated subs + events
%% (a beam event describing the path, plus a hit event if it connected).
fire_beam(Board, Subs, Id, Kind, Dmg, DepthGated) ->
    Sub = maps:get(Id, Subs),
    Dir = dir_vec(maps:get(facing, Sub)),
    Depth = maps:get(depth, Sub),
    {Fx, Fy} = pos(Subs, Id),
    {Path, HitId} =
        trace(Board, Subs, Id, add({Fx, Fy}, Dir), Dir, Depth, DepthGated, []),
    Base = #{<<"x">> => Fx, <<"y">> => Fy, <<"depth">> => Depth,
             <<"path">> => [xy(P) || P <- Path]},
    case HitId of
        none ->
            {Subs, [event(Kind, Id, Base#{<<"hit">> => null})]};
        Tgt ->
            Subs1 = hurt(Subs, Tgt, Dmg),
            {Subs1,
             [event(Kind, Id, Base#{<<"hit">> => Tgt}),
              event(<<"hit">>, Tgt,
                    #{<<"by">> => Id, <<"weapon">> => Kind, <<"damage">> => Dmg})]}
    end.

%% Walk one tile at a time until a wall/edge stops the beam or an enemy sub
%% is found. Returns `{PathTiles, HitId | none}`.
trace(Board, Subs, Owner, Coord, Dir, Depth, DepthGated, Path) ->
    case passable(Board, Coord) of
        false ->
            {lists:reverse(Path), none};
        true ->
            case sub_at(Subs, Coord, Depth, DepthGated, Owner) of
                {ok, TgtId} -> {lists:reverse([Coord | Path]), TgtId};
                none -> trace(Board, Subs, Owner, add(Coord, Dir), Dir,
                              Depth, DepthGated, [Coord | Path])
            end
    end.

%% Find an alive enemy on a tile. When depth-gated, only same-depth subs
%% count (torpedoes); otherwise depth is ignored (sonar).
sub_at(Subs, Coord, Depth, DepthGated, Except) ->
    Found = [Id || Id <- alive_ids(Subs),
                   Id =/= Except,
                   pos(Subs, Id) =:= Coord,
                   (not DepthGated)
                       orelse maps:get(depth, maps:get(Id, Subs)) =:= Depth],
    case Found of
        [Id | _] -> {ok, Id};
        [] -> none
    end.

%% Detonate a set of armed depth charges: every sub on the tile (either
%% depth) takes damage.
detonate(Subs, []) ->
    {Subs, []};
detonate(Subs, Armed) ->
    lists:foldl(
      fun(#{owner := Owner, x := X, y := Y}, {S, Evs}) ->
          Targets = [Id || Id <- alive_ids(S), pos(S, Id) =:= {X, Y}],
          S1 = lists:foldl(fun(T, Acc) -> hurt(Acc, T, ?DMG_DEPTH_CHARGE) end,
                           S, Targets),
          HitEvs = [event(<<"hit">>, T,
                          #{<<"by">> => Owner, <<"weapon">> => <<"depth_charge">>,
                            <<"damage">> => ?DMG_DEPTH_CHARGE}) || T <- Targets],
          {S1, Evs ++ [event(<<"explosion">>, Owner,
                             #{<<"x">> => X, <<"y">> => Y})] ++ HitEvs}
      end,
      {Subs, []},
      Armed).

%% Depth charges armed on the last register (with no register after them to
%% delay into) go off at the end of the round.
final_detonate(_Board, St, Phases) ->
    case maps:get(armed, St) of
        [] ->
            {St, Phases};
        Armed ->
            {Subs1, E1} = detonate(maps:get(subs, St), Armed),
            {Subs2, E2} = reap(Subs1),
            St1 = St#{subs => Subs2, armed => []},
            {St1, append_to_last(Phases, E1 ++ E2, snapshot(Subs2))}
    end.

append_to_last(Phases, [], _Snap) ->
    Phases;
append_to_last(Phases, Extra, Snap) ->
    case lists:reverse(Phases) of
        [] ->
            Phases;
        [Last | Rest] ->
            Last1 = Last#{<<"events">> => maps:get(<<"events">>, Last) ++ Extra,
                          <<"submarines">> => Snap},
            lists:reverse([Last1 | Rest])
    end.

%% --- movement resolution ----------------------------------------------

%% Resolve a set of movers one unit step at a time. `Ram` toggles collision
%% damage (true for programmed movement, false for gentle current drift).
step_movers(_Board, Subs, [], _Ram) ->
    {Subs, []};
step_movers(Board, Subs, Movers, Ram) ->
    step_loop(Board, Subs, Movers, Ram, []).

step_loop(_Board, Subs, [], _Ram, Evs) ->
    {Subs, Evs};
step_loop(Board, Subs, Movers, Ram, Evs) ->
    {Subs1, StepEvs, Next} = unit_step(Board, Subs, Movers, Ram),
    step_loop(Board, Subs1, Next, Ram, Evs ++ StepEvs).

%% A single simultaneous unit step. Returns the new subs, any events, and
%% the movers that still have steps left. `Ram` enables collision damage.
unit_step(Board, Subs, Movers, Ram) ->
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

    Subs1 = lists:foldl(
              fun({Id, _Dir, _Steps, _From, {X, Y}}, Acc) ->
                  S = maps:get(Id, Acc),
                  maps:put(Id, S#{x => X, y => Y}, Acc)
              end, Subs, Success),

    %% ramming: movers stopped by another sub take damage (walls don't hurt)
    SubBlocked = Contended ++ Swapped ++ Demoted,
    RamIds = case Ram of
                 true ->
                     Movers2 = [Id || {Id, _, _, _, _} <- SubBlocked],
                     Occupants = [OccId
                                  || {_, _, _, _, T} <- Demoted,
                                     OccId <- occupants_at(Subs, T)],
                     lists:usort(Movers2 ++ Occupants);
                 false ->
                     []
             end,
    Subs2 = lists:foldl(fun(Id, Acc) -> hurt(Acc, Id, ?DMG_RAM) end,
                        Subs1, RamIds),

    Evs = [event(<<"blocked">>, Id, #{}) || {Id, _, _, _, _} <- Blocked0]
          ++ [event(<<"ram">>, Id, #{}) || Id <- RamIds],
    Next = [{Id, Dir, Steps - 1}
            || {Id, Dir, Steps, _F, _T} <- Success, Steps - 1 > 0],
    {Subs2, Evs, Next}.

occupants_at(Subs, Coord) ->
    [Id || Id <- lists:sort(maps:keys(Subs)), pos(Subs, Id) =:= Coord].

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
%% currents. Drift reuses the movement resolver (walls/subs respected) but
%% without ramming damage.
apply_currents(Board, Subs) ->
    {Subs1, TurbEvents} = apply_turbulence(Board, Subs),
    Drifters = [{Id, dir_vec(dir_bin(Dir)), Str}
                || Id <- alive_ids(Subs1),
                   {Dir, Str} <- [stw_board:current_at(Board, pos(Subs1, Id))],
                   Dir =/= none],
    {Subs2, MoveEvents} = step_movers(Board, Subs1, Drifters, false),
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
      alive_ids(Subs)).

%% --- hazards ----------------------------------------------------------

%% Entering a mine tile: heavy damage, scramble the next register into
%% inert "drift", and consume the mine so it only fires once per round.
apply_mines(Board, Subs, Programs, R, Cleared) ->
    lists:foldl(
      fun(Id, {S, Evs, Progs, Cl}) ->
          C = pos(S, Id),
          IsMine = stw_board:tile_at(Board, C) =:= mine,
          case IsMine andalso not lists:member(C, Cl) of
              true ->
                  {X, Y} = C,
                  S1 = hurt(S, Id, ?DMG_MINE),
                  Progs1 = scramble(Progs, Id, R),
                  Ev = event(<<"mine">>, Id,
                             #{<<"x">> => X, <<"y">> => Y,
                               <<"scrambled">> => scrambled_reg(R)}),
                  {S1, Evs ++ [Ev], Progs1, [C | Cl]};
              false ->
                  {S, Evs, Progs, Cl}
          end
      end,
      {Subs, [], Programs, Cleared},
      alive_ids(Subs)).

%% Replace the register after R with inert drift (a lost register).
scramble(Programs, Id, R) ->
    case maps:find(Id, Programs) of
        {ok, Cards} when length(Cards) > R + 1 ->
            maps:put(Id, replace_nth(R + 2, <<"drift">>, Cards), Programs);
        _ ->
            Programs
    end.

scrambled_reg(R) when R < ?REGISTERS - 1 -> R + 1;
scrambled_reg(_) -> null.

%% A Deep sub sitting on a thermal vent is forced up to Shallow.
apply_vents(Board, Subs) ->
    lists:foldl(
      fun(Id, {S, Evs}) ->
          Sub = maps:get(Id, S),
          OnVent = stw_board:tile_at(Board, pos(S, Id)) =:= vent,
          case OnVent andalso maps:get(depth, Sub) =:= <<"deep">> of
              true ->
                  {maps:put(Id, Sub#{depth => <<"shallow">>}, S),
                   Evs ++ [event(<<"vent">>, Id, #{})]};
              false ->
                  {S, Evs}
          end
      end,
      {Subs, []},
      alive_ids(Subs)).

%% --- damage & destruction ---------------------------------------------

hurt(Subs, Id, Amount) ->
    S = maps:get(Id, Subs),
    maps:put(Id, S#{hull => maps:get(hull, S) - Amount}, Subs).

%% Mark any sub whose hull has dropped to zero as a wreck (once).
reap(Subs) ->
    lists:foldl(
      fun(Id, {Acc, Evs}) ->
          S = maps:get(Id, Acc),
          case maps:get(alive, S, true) andalso maps:get(hull, S) =< 0 of
              true ->
                  {maps:put(Id, S#{alive => false}, Acc),
                   Evs ++ [event(<<"destroyed">>, Id, #{})]};
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
action(<<"torpedo">>) -> {fire, torpedo};
action(<<"sonar_ping">>) -> {fire, sonar};
action(<<"depth_charge">>) -> {arm, depth_charge};
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

%% Only alive submarines take actions; wrecks remain as blockers.
alive_ids(Subs) ->
    [Id || Id <- lists:sort(maps:keys(Subs)),
           maps:get(alive, maps:get(Id, Subs), true)].

%% Backfill hull/alive so callers can pass minimal sub maps.
ensure_fields(Subs) ->
    maps:map(fun(_, S) ->
                 S#{hull => maps:get(hull, S, 10),
                    alive => maps:get(alive, S, true)}
             end, Subs).

replace_nth(N, V, List) ->
    {Head, [_ | Tail]} = lists:split(N - 1, List),
    Head ++ [V | Tail].

tally(List) ->
    lists:foldl(fun(K, Acc) -> maps:update_with(K, fun(V) -> V + 1 end, 1, Acc) end,
                #{}, List).

xy({X, Y}) -> #{<<"x">> => X, <<"y">> => Y}.

event(Type, Id, Extra) ->
    Extra#{<<"type">> => Type, <<"player_id">> => Id}.

snapshot(Subs) ->
    [begin
         S = maps:get(Id, Subs),
         #{<<"player_id">> => Id,
           <<"x">> => maps:get(x, S),
           <<"y">> => maps:get(y, S),
           <<"facing">> => maps:get(facing, S),
           <<"depth">> => maps:get(depth, S),
           <<"hull">> => maps:get(hull, S),
           <<"alive">> => maps:get(alive, S, true)}
     end || Id <- lists:sort(maps:keys(Subs))].
