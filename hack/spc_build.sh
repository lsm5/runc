#!/bin/bash

set -e

if [[ "$SPC" != "true" ]]
then
    echo "This script is intended to be executed in an SPC,"
    echo "by run_ci_tests.sh. Using it otherwise may result"
    echo "in unplesent side-effects."
    exit 1
fi

echo
echo "Build Environment:"
env

set +x


echo "Updating image and deps..."
sudo apt -qq update
sudo apt -qqy dist-upgrade

echo "Owning everything in $HOME..."
sudo chown -R lsm5-bot:lsm5-bot /home/lsm5-bot

# Setup SSH key
echo "Copying SSH key..."
pushd $HOME/.ssh
openssl enc -aes-256-cbc -d -in id_rsa.enc -out id_rsa -pass pass:$DECRYPTION_PASSPHRASE
echo "Set correct permissions for SSH priv key..."
chmod 600 $HOME/.ssh/id_rsa
popd

# Import GPG priv key
echo "Importing GPG priv key..."
pushd $HOME
openssl enc -aes-256-cbc -d -in lsm5-bot-privkey.enc -out lsm5-bot-privkey.asc -pass pass:$DECRYPTION_PASSPHRASE
echo $GPG_KEY_PASSPHRASE | gpg --passphrase-fd 0 --allow-secret-key-import --import $(pwd)/lsm5-bot-privkey.asc
popd

echo "Adding and fetching git upstream remote..."
git remote add upstream github:opencontainers/runc.git
git remote add lsm5 github:lsm5/runc.git
git fetch --all
git checkout bionic

echo "Extracting commit id..."
export COMMIT=$(git show --pretty=%H -s upstream/master)
export SHORTCOMMIT=$(c=$COMMIT; echo ${c:0:7})

echo "Extracting current version and commit from deb package..."
export CURRENT_VERSION=$(dpkg-parsechangelog --show-field Version | sed -e 's/-.*//')
export CURRENT_SHORTCOMMIT=$(dpkg-parsechangelog --show-field Changes | grep autobuilt | sed -e 's/.* autobuilt //')

# Build only if new changes upstream
if [[ $SHORTCOMMIT == $CURRENT_SHORTCOMMIT ]]; then
    echo "Exiting since no changes upstream..."
    exit 0
else
    git rebase upstream/master
    export VERSION=$(cat VERSION | sed -e 's/-.*//')
    echo "Setting git and packager name and email..."
    export NAME="Lokesh Mandvekar (Bot)"
    export EMAIL="lsm5+bot@fedoraproject.org"
    export USER="lsm5-bot"
    git config --global user.name "$NAME"
    git config --global user.email "$EMAIL"

    export DEBFULLNAME=$NAME
    export DEBEMAIL=$EMAIL

    echo "Bumping changelog..."
    if [[ $VERSION == $CURRENT_VERSION ]]; then
       debchange -i -D bionic "autobuilt $SHORTCOMMIT"
       git commit -asm "autobuilt $SHORTCOMMIT"
    else
       debchange --package "runc" -v "$VERSION-1~dev~ubuntu18.04~ppa1" -D bionic "bump to $VERSION, autobuilt $SHORTCOMMIT"
       git commit -asm "bump to $VERSION, autobuilt $SHORTCOMMIT"
    fi

    echo "Building package..."
    debuild -i -us -uc -S -sa

    echo "Signing deb package..."
    echo "Y" | debsign -e"$DEBFULLNAME <$DEBEMAIL>" -p"gpg --yes -q --passphrase $GPG_KEY_PASSPHRASE --batch"\
        ../*.dsc
    echo "Y" | debsign -e"$DEBFULLNAME <$DEBEMAIL>" -p"gpg --yes -q --passphrase $GPG_KEY_PASSPHRASE --batch"\
        ../*_source.changes

    echo "Submitting build to PPA..."
    dput ppa:projectatomic/ppa ../*_source.changes

    echo "Pushing changes to lsm5/runc..."
    GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_rsa" git push -u lsm5 bionic -f
    echo "Done!!!"
fi
