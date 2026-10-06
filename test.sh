#!/bin/bash
d=$(mktemp -d); mkdir -p $d/{root-creds,gitea-s3-creds,db-password,filer-config,shared}
for f in root-creds/username root-creds/password gitea-s3-creds/access_key gitea-s3-creds/secret_key db-password/db_password; do echo test
> $d/$f; done
echo '# filer' > $d/filer-config/filer.toml; chmod -R a+rX $d; chmod 777 $d/shared
script="$(helm template t platform/storage/seaweedfs | yq 'select(.kind=="Deployment").spec.template.spec.initContainers[0].command[2]')"
podman run --rm --read-only --tmpfs /tmp --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
  $(for v in root-creds gitea-s3-creds db-password; do printf -- '-v %s/%s:/secrets/%s:ro,z ' $d $v $v; done) \
  -v $d/filer-config:/etc/filer-config:ro,z -v $d/shared:/shared:z \
  docker.io/library/busybox:1.36 sh -c "$script" && ls -l $d/shared && tail -3 $d/shared/filer.toml

