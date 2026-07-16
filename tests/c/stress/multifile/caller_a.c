int core(int);
int caller_a(int x) { return core(x) + 1; }
