# Unit tests for O(1) coset indexing and fail-closed lookup.
# Expects generate_rrm_v11_fast.g to define RrmVertexIndex(offset, rt, eq, g).

nfail := 0;;
npass := 0;;

AssertEq := function(got, want, msg)
    if got <> want then
        nfail := nfail + 1;
        Print("FAIL ", msg, " got=", got, " want=", want, "\n");
    else
        npass := npass + 1;
    fi;
end;;

Read("generate_rrm_v11_fast.g");

if not IsBound(RrmVertexIndex) then
    Error("RrmVertexIndex is not defined in generate_rrm_v11_fast.g\n");
fi;

# Same construction as generate_rrm_v11.g vertices: one EQ, transversal order,
# store CanonicalRightCosetElement. Index must match Position(vertices, p).
G := Group((1,2,3,4),(1,2));;
U := Subgroup(G, [(1,2)(3,4),(1,3)(2,4)]);;
rt := RightTransversal(G, U);;
vertices := [];;
for rturi in rt do
    Append(vertices, [[1, CanonicalRightCosetElement(U, rturi)]]);
od;;
offset := [0];;
rts := [rt];;

for p in vertices do
    AssertEq(RrmVertexIndex(offset, rts, p[1], p[2]),
             Position(vertices, p),
             "canonical representative");
od;

for g in G do
    v := [1, CanonicalRightCosetElement(U, g)];
    AssertEq(RrmVertexIndex(offset, rts, 1, g),
             Position(vertices, v),
             "lookup via non-canonical g");
od;

# Two EQs: ids are offset[eq] + position-in-transversal.
U2 := Subgroup(G, [(1,2)]);;
rt2 := RightTransversal(G, U2);;
offset2 := [0, Length(rt)];;
rts2 := [rt, rt2];;
vertices2 := [];;
for rturi in rt do
    Append(vertices2, [[1, CanonicalRightCosetElement(U, rturi)]]);
od;
for rturi in rt2 do
    Append(vertices2, [[2, CanonicalRightCosetElement(U2, rturi)]]);
od;
for p in vertices2 do
    AssertEq(RrmVertexIndex(offset2, rts2, p[1], p[2]),
             Position(vertices2, p),
             "two-EQ block");
od;

Print("npass=", npass, " nfail=", nfail, "\n");
if nfail <> 0 then
    FORCE_QUIT_GAP(1);
fi;
