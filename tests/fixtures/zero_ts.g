# TS=0 fixture (issue #17): a single EQ and no transition states.
# Empty edge output is legitimate here; it is not evidence of a correct map.
# Exercises the driver path where rrm_active_workers returns 0.
sym:=Group([(1,2),(1,2,3)]);
symc:=sym;
ur:=[Group([()])];
urt:=[];
ss:=[];
org_eq:=[1];
org_ts:=[];
