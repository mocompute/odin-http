## autobahn websocket test suite

```
docker run -it --rm \
  -v "$PWD/config:/config" \
  -v "$PWD/reports:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json
```
