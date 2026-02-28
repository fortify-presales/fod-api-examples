# sbom-import

A quick example to import Cyclone DX via FoD API. You will need to set the following environment variables:

 - FCLI_DEFAULT_FOD_CLIENT_ID
 - FCLI_DEFAULT_FOD_CLIENT_SECRET
 - FCLI_DEFAULT_FOD_RELEASE_ID

then run `sbom-import.sh`, for example:

```
export FCLI_DEFAULT_FOD_CLIENT_ID=...
export FCLI_DEFAULT_FOD_CLIENT_SECRET=...
export FCLI_DEFAULT_FOD_RELEASE_ID=12345
./sbom-import.sh
```

kadraman (klee2@opentext.com)
