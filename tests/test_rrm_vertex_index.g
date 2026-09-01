# Unit tests for hash-based coset indexing (issue #10).
# RrmBuildTransversals must expose a SparseHashTable per EQ.
# RrmVertexIndex(offset, idx, ur, eq, g) must match v11 Position(vertices, p).

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

AssertTrue := function(cond, msg)
    if not cond then
        nfail := nfail + 1;
        Print("FAIL ", msg, "\n");
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
built := RrmBuildTransversals(G, [U]);;
AssertTrue(IsBound(built.idx), "built.idx exists");
AssertTrue(IsHash(built.idx[1]), "EQ index is a hash table, not a sort dict");
AssertTrue(not IsSortLookupDictionary(built.idx[1]),
           "EQ index must not be NewDictionary sort fallback");

rt := built.rt[1];;
vertices := [];;
for rturi in rt do
    Append(vertices, [[1, CanonicalRightCosetElement(U, rturi)]]);
od;;
offset := built.offset;;
idx := built.idx;;
urs := [U];;

for p in vertices do
    AssertEq(RrmVertexIndex(offset, idx, urs, p[1], p[2]),
             Position(vertices, p),
             "canonical representative");
od;

for g in G do
    v := [1, CanonicalRightCosetElement(U, g)];
    AssertEq(RrmVertexIndex(offset, idx, urs, 1, g),
             Position(vertices, v),
             "lookup via non-canonical g");
od;

# Two EQs: ids are offset[eq] + position-in-transversal.
U2 := Subgroup(G, [(1,2)]);;
built2 := RrmBuildTransversals(G, [U, U2]);;
AssertTrue(IsHash(built2.idx[1]) and IsHash(built2.idx[2]),
           "each EQ gets a hash table");
vertices2 := [];;
for rturi in built2.rt[1] do
    Append(vertices2, [[1, CanonicalRightCosetElement(U, rturi)]]);
od;
for rturi in built2.rt[2] do
    Append(vertices2, [[2, CanonicalRightCosetElement(U2, rturi)]]);
od;
for p in vertices2 do
    AssertEq(RrmVertexIndex(built2.offset, built2.idx, [U, U2], p[1], p[2]),
             Position(vertices2, p),
             "two-EQ block");
od;

# Trivial point group: RightTransversal is Enumerator(G), not a perm RT.
U0 := TrivialSubgroup(G);;
built0 := RrmBuildTransversals(G, [U0]);;
AssertTrue(IsHash(built0.idx[1]), "trivial-U index is still a hash");
vertices0 := [];;
for rturi in built0.rt[1] do
    Append(vertices0, [[1, CanonicalRightCosetElement(U0, rturi)]]);
od;
for g in G do
    v := [1, CanonicalRightCosetElement(U0, g)];
    AssertEq(RrmVertexIndex(built0.offset, built0.idx, [U0], 1, g),
             Position(vertices0, v),
             "trivial point group");
od;

Print("npass=", npass, " nfail=", nfail, "\n");
if nfail <> 0 then
    FORCE_QUIT_GAP(1);
fi;
