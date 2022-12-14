# CHANGELOG

#### Releasing new versions

- create a release branch
- update the changelog below
- update version and copyright-years in `./LICENSE` and `./src/copas-sse/client.lua` (in doc-comments
  header, and in module constants)
- create a new rockspec and update the version inside the new rockspec:<br/>
  `cp copas-sse-scm-1.rockspec ./rockspecs/copas-sse-X.Y.Z-1.rockspec`
- test: run `make test` and `make lint`
- clean and render the docs: run `make clean` and `make docs`
- commit the changes as `release X.Y.Z`
- push the commit, and create a release PR
- after merging tag the release commit with `X.Y.Z`
- upload to LuaRocks:<br/>
  `luarocks upload ./rockspecs/copas-sse-X.Y.Z-1.rockspec --api-key=ABCDEFGH`
- test the newly created rock:<br/>
  `luarocks install copas-sse`

### Version 0.2.0, unreleased

- Fix: switch to newer Copas version to use `pause` instead of `sleep`

### Version 0.1.0, released 06-Sep-2022

- Fix: added cache-control header to request
- Feat: add event_timeout option (reconnect if stream is idle for too long)
- Dep: bump Copas dependency to 4.2

### Version 0.0.3, released 28-Aug-2022

- rewrote the interface, integrates queue creation/destruction

### Version 0.0.2, released 26-Aug-2022

- Added: logging
- Change: format of 'data' field to the more sane format by MDN. But leaving
  options for table and the WHATWG format.

### Version 0.0.1, released 25-Aug-2022

- initial release
