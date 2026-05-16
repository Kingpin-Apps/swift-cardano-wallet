build:
    swift build

test:
    swift test

release:
    swift build -c release

# Clean .build and rebuild from scratch. Use after `swift package update`
# bumps swift-secp256k1 (or any other plugin-using dep) — the upstream
# SharedSourcesPlugin uses `cp` instead of `rsync --delete`, so source
# reorganizations leave stale .swift files in the plugin output dir and
# the next build fails with thousands of duplicate-symbol errors.
clean-build:
    rm -rf .build
    swift build

# Update changelog
changelog:
    cz ch

# Bump version according to changelog
bump: changelog
    cz bump
