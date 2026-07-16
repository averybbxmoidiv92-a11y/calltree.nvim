int core(int);
int caller_b(int x) { return core(x) + 2; }
