set shell := ["zsh", "-cu"]

derived_data := "build"
app := derived_data + "/Build/Products/Release/DockDoor.app"

# Fetch latest from upstream (ejbills/DockDoor) and merge into current branch
sync:
    git remote get-url upstream &>/dev/null || git remote add upstream https://github.com/ejbills/DockDoor.git
    git fetch upstream
    git merge upstream/main

# Build Release with auto-bumped version and install into /Applications.
# Bump type comes from commits since the last deploy (tracked in .deploy-state.json):
# breaking change -> major, feat -> minor, anything else -> patch.
deploy:
    #!/usr/bin/env zsh
    set -euo pipefail

    state=.deploy-state.json
    if [[ -f $state ]]; then
        version=$(python3 -c "import json; print(json.load(open('$state'))['version'])")
        last=$(python3 -c "import json; print(json.load(open('$state'))['commit'])")
    else
        # Seed from the newest release in upstream's appcast, fall back to pbxproj
        version=$(grep -o 'shortVersionString>[0-9.]*' appcast.xml | cut -d'>' -f2 | sort -V | tail -1)
        [[ -n $version ]] || version=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' DockDoor.xcodeproj/project.pbxproj | head -1)
        version=$(echo $version | cut -d. -f1-3)
        last=""
    fi

    if [[ -z $last ]]; then
        count=0
        echo "==> First deploy, using baseline version: $version"
    else
        count=$(git rev-list --count $last..HEAD 2>/dev/null || echo 0)
    fi

    if (( count > 0 )); then
        log=$(git log --format='%s%n%b' $last..HEAD)
        major=$(echo $version | cut -d. -f1)
        minor=$(echo $version | cut -d. -f2)
        patch=$(echo $version | cut -d. -f3)
        if grep -qE '^[a-z]+(\(.*\))?!:|BREAKING CHANGE' <<< "$log"; then
            version="$((major + 1)).0.0"
        elif grep -qE '^feat(\(.*\))?:' <<< "$log"; then
            version="$major.$((minor + 1)).0"
        else
            version="$major.$minor.$((patch + 1))"
        fi
        echo "==> $count commit(s) since last deploy, new version: $version"
    elif [[ -n $last ]]; then
        echo "==> No new commits, keeping version: $version"
    fi

    xcodebuild -project DockDoor.xcodeproj -scheme DockDoor -configuration Release \
        -derivedDataPath {{derived_data}} \
        MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version build

    pkill -x DockDoor || true
    rm -rf /Applications/DockDoor.app
    cp -R "{{app}}" /Applications/
    open /Applications/DockDoor.app

    python3 -c "import json; json.dump({'version': '$version', 'commit': '$(git rev-parse HEAD)'}, open('$state', 'w'), indent=2)"
    echo "==> Deployed DockDoor $version to /Applications"
