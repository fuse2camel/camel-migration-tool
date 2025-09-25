## build and runcommand
```
# 1) Setup (no data insert, just DB/extension/tables/users):
chmod +x setup_pgvector.sh
./setup_pgvector.sh

# 2) (Optional) Run a quick insert + search demo, separately:
chmod +x test_pgvector.sh
./test_pgvector.sh

# 3.1) Remove EVERYTHING pgvector|vectordb + prune build cache
chmod +x teardown_pgvector.sh
./teardown_pgvector.sh --zap -f --prune-build-cache


# 3.2) 

```