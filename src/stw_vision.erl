%%%-------------------------------------------------------------------
%% @doc Per-submarine visibility (fog of war), pure and deterministic.
%%
%% A submarine sees a limited slice of the board around it: a small radius
%% in every direction (its immediate surroundings) plus a wider cone in the
%% direction it faces (its sonar sweep). Line of sight is blocked by walls,
%% so a submarine cannot see around corners or through rock.
%%
%% Two sonar modes trade coverage for stealth:
%%   passive  short range, silent
%%   active   longer range and a wider near radius, but the game server
%%            broadcasts an active sub's position to everyone (handled by
%%            `stw_game`, not here)
%%
%% Depth also matters: a Deep submarine's sonar cone is shortened, so diving
%% trades visibility for protection.
%%
%% The module has no side effects: `visible_tiles/3` is a pure function of
%% the board, the submarine, and the sonar mode.
%% @end
%%%-------------------------------------------------------------------
-module(stw_vision).

-export([visible_tiles/3, sees/4]).

-type mode() :: active | passive.
-type coord() :: {integer(), integer()}.

-export_type([mode/0]).

%% Immediate all-around radius (Chebyshev distance) by sonar mode.
-define(NEAR_PASSIVE, 1).
-define(NEAR_ACTIVE, 2).
%% Forward sonar cone length by sonar mode.
-define(CONE_PASSIVE, 3).
-define(CONE_ACTIVE, 5).
%% A Deep submarine's cone is shortened by this much.
-define(DEEP_PENALTY, 1).

%% @doc Every tile the submarine can currently see, including its own tile.
%% Walls that bound the view are themselves visible (you see the rock that
%% stops you), but tiles behind a wall are not.
-spec visible_tiles(stw_board:board(), map(), mode()) -> [coord()].
visible_tiles(Board, Sub, Mode) ->
    {W, H} = stw_board:dims(Board),
    {X, Y} = pos(Sub),
    F = maps:get(facing, Sub),
    {Near, Cone} = ranges(Mode, deep(Sub)),
    [{Tx, Ty}
     || Tx <- lists:seq(0, W - 1),
        Ty <- lists:seq(0, H - 1),
        in_view(X, Y, F, Near, Cone, {Tx, Ty}),
        has_los(Board, {X, Y}, {Tx, Ty})].

%% @doc Whether a single tile is visible to the submarine.
-spec sees(stw_board:board(), map(), mode(), coord()) -> boolean().
sees(Board, Sub, Mode, {_, _} = Coord) ->
    {X, Y} = pos(Sub),
    F = maps:get(facing, Sub),
    {Near, Cone} = ranges(Mode, deep(Sub)),
    in_view(X, Y, F, Near, Cone, Coord)
        andalso has_los(Board, {X, Y}, Coord).

%% --- view geometry ----------------------------------------------------

ranges(Mode, Deep) ->
    Near = near_radius(Mode),
    Cone = max(1, cone_len(Mode) - deep_penalty(Deep)),
    {Near, Cone}.

near_radius(active) -> ?NEAR_ACTIVE;
near_radius(passive) -> ?NEAR_PASSIVE.

cone_len(active) -> ?CONE_ACTIVE;
cone_len(passive) -> ?CONE_PASSIVE.

deep_penalty(true) -> ?DEEP_PENALTY;
deep_penalty(false) -> 0.

%% A tile is in view if it is within the near radius (any direction) or
%% within the forward cone (in front, out to the cone length, spreading no
%% wider than its forward distance -> a 90-degree wedge).
in_view(X, Y, F, Near, Cone, {Tx, Ty}) ->
    Dx = Tx - X,
    Dy = Ty - Y,
    Cheb = max(abs(Dx), abs(Dy)),
    case Cheb =< Near of
        true ->
            true;
        false ->
            {Fwd, Lat} = project(F, Dx, Dy),
            Fwd >= 1 andalso Fwd =< Cone andalso Lat =< Fwd
    end.

%% Forward / lateral distance of an offset relative to a facing.
project(<<"N">>, Dx, Dy) -> {-Dy, abs(Dx)};
project(<<"S">>, Dx, Dy) -> {Dy, abs(Dx)};
project(<<"E">>, Dx, Dy) -> {Dx, abs(Dy)};
project(<<"W">>, Dx, Dy) -> {-Dx, abs(Dy)}.

%% --- line of sight ----------------------------------------------------

%% Clear line of sight if no wall sits strictly between the two tiles. The
%% endpoints themselves are not checked (the viewer stands on one; the other
%% may legitimately be a wall the viewer can see).
has_los(Board, From, To) ->
    Inner = middle(line(From, To)),
    not lists:any(fun(C) -> stw_board:tile_at(Board, C) =:= wall end, Inner).

middle(Line) ->
    case Line of
        [] -> [];
        [_] -> [];
        [_ | Tail] -> lists:droplast(Tail)
    end.

%% Integer Bresenham line from P0 to P1 (inclusive of both endpoints).
line({X0, Y0}, {X1, Y1}) ->
    Dx = abs(X1 - X0),
    Dy = -abs(Y1 - Y0),
    Sx = step(X0, X1),
    Sy = step(Y0, Y1),
    bres(X0, Y0, X1, Y1, Dx, Dy, Sx, Sy, Dx + Dy, []).

bres(X, Y, X1, Y1, Dx, Dy, Sx, Sy, Err, Acc) ->
    Acc1 = [{X, Y} | Acc],
    case X =:= X1 andalso Y =:= Y1 of
        true ->
            lists:reverse(Acc1);
        false ->
            E2 = 2 * Err,
            {Err1, X2} =
                case E2 >= Dy of
                    true -> {Err + Dy, X + Sx};
                    false -> {Err, X}
                end,
            {Err2, Y2} =
                case E2 =< Dx of
                    true -> {Err1 + Dx, Y + Sy};
                    false -> {Err1, Y}
                end,
            bres(X2, Y2, X1, Y1, Dx, Dy, Sx, Sy, Err2, Acc1)
    end.

step(A, B) when B > A -> 1;
step(A, B) when B < A -> -1;
step(_, _) -> 0.

%% --- helpers ----------------------------------------------------------

pos(Sub) -> {maps:get(x, Sub), maps:get(y, Sub)}.

deep(Sub) -> maps:get(depth, Sub) =:= <<"deep">>.
