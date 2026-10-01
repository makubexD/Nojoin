# Every image this fork runs, in one place.
#
# NojoinTag is the image tag, not the git tag. Upstream tags releases vX.Y.Z
# and publish.yml strips the leading "v" before pushing to GHCR
# (.github/workflows/release.yml, version="${tag_name#v}"). The compose
# override cannot read this file, so it repeats the tag as the
# ${NOJOIN_IMAGE_TAG:-<tag>} default. `images pin` rewrites both, and
# `images verify` fails when they disagree.
#
#   .\contrib\maku.ps1 images show
#   .\contrib\maku.ps1 images pin v2.5.1
#   .\contrib\maku.ps1 images verify

@{
    NojoinTag = '2.5.1'

    # ghcr.io/valtora/nojoin-* repositories. The tag is NojoinTag.
    Api      = 'ghcr.io/valtora/nojoin-api'
    Worker   = 'ghcr.io/valtora/nojoin-worker'
    WorkerIo = 'ghcr.io/valtora/nojoin-worker-io'
    Frontend = 'ghcr.io/valtora/nojoin-frontend'

    # Third-party images, already fully qualified. Not release-pinned.
    Postgres    = 'docker.io/pgvector/pgvector:pg18-trixie'
    Redis       = 'docker.io/library/redis:alpine'
    Nginx       = 'docker.io/library/nginx:alpine'
    SocketProxy = 'docker.io/tecnativa/docker-socket-proxy'

    # Files that repeat NojoinTag inside ${NOJOIN_IMAGE_TAG:-<tag>}.
    TagMirrors = @(
        'contrib/podman/compose.podman.yml'
    )
}
