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


### Version 0.1.0, unreleased

  - Added: logging
  - Change: format of 'data' field to the more sane format by MDN. But leaving
    options for table and the WHATWG format.

### Version 0.0.1, released 25-Aug-2022

  - initial release
