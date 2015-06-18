#!/bin/bash
dryrun=0
use_existing_checkouts=0
while getopts "v:db:e" opt; do
	case $opt in
		v)
			ver=$OPTARG
			;;
		d)
			dryrun=1
			;;
		b)
			branch=$OPTARG
			;;
		e)
			use_existing_checkouts=1
			;;
		\?)
			echo 'No'
			;;

	esac
done

# Check that there is a version provided
if [ "$ver" == '' ]; then
	echo "No version provided. Please provide a value for -v."
	exit
fi

# Check that there is a branch provided
if [ "$branch" == '' ]; then
	echo "No branch provided. Please provide a value for -b."
	exit
fi

if [ $dryrun -eq 0 ]; then
	read -n 1 -p "I understand that this is NOT a dry run (y/n)? " answer
	echo ""
	if [ "$answer" != 'y' ]; then
		echo "Get outta here then"
		exit 1
	fi
fi

echo "Preparing BuddyPress $ver from source branch $branch."

if [ $dryrun -eq 0 ]; then
	echo "*** This is NOT a dry run ***"
else
	echo "*** This is a dry run ***"
fi

# Set up the buddypress.svn checkout.
if [ $use_existing_checkouts -eq 0 ]; then
	echo "Getting a checkout of the $branch branch."
	# Remove existing bp working directory.
	if [ -d "bp" ]; then
		rm -rf ./bp
	fi

	# Get a checkout of the branch.
	svn co http://buddypress.svn.wordpress.org/branches/$branch bp
else
	if [[ ! -d 'bp' ]] || [[ ! -f 'bp/Gruntfile.js' ]]; then
		echo "No checkout found. Please try again without the -e flag."
		exit 1
	else
		echo "Using your existing $branch checkout."
	fi
fi

cd bp

# Version number replacements.
# Version: x.y.z in bp-loader.php
ver_regex='s/\(^ \* Version\:\s\+\)\([0-9\.]\+\)/\1'"$ver"/
sed -i "{$ver_regex}" bp-loader.php
sed -i "{$ver_regex}" src/bp-loader.php

# $this->version in bp-loader.php
inline_ver_regex="s/\(\$this\->version\s\+= '\)[0-9\.]\+/\1""$ver"/
sed -i "{$inline_ver_regex}" src/bp-loader.php

# Stable tag in readme.txt
stable_regex='s/\(^Stable tag\:\s\+\)\([0-9\.]\+\)/\1'"$ver"/
sed -i "{$stable_regex}" src/readme.txt

# Upgrade Notice and Changelog
# Only add it if it hasn't already been added.
already=$( grep -c "= $ver =" src/readme.txt )
if [ $already -eq 0 ]; then
	ver_hyphens="$(sed -e "s/\./-/g" <<< "$ver")"
	see="\n\n= $ver =\nSee: https:\/\/codex.buddypress.org\/releases\/version-$ver_hyphens\/"

	upgrade_regex='s/\(\(Upgrade Notice\|Changelog\).*\)/\1'"$see"/g
	sed -i "{$upgrade_regex}" src/readme.txt

	# $this->db_version in bp-loader.php should also only be updated when necessary.
	lastrev="$(svn log -l 1 http://buddypress.svn.wordpress.org | grep -oP "^r([0-9]+) \| ")"
	lastrev="$(sed -e "s/[^0-9]//g" <<< "$lastrev")"
	db_ver_regex="s/\(\$this\->db_version\s\+= \)[0-9\.]\+/\1""$lastrev"/
	sed -i "{$db_ver_regex}" src/bp-loader.php
fi

echo "Version numbers bumped to $ver."

# Commit version bumps.
commit_message_bump="Bumping version numbers to $ver."
if [ $dryrun -eq 0 ]; then
	read -n 1 -p "Ready to commit and tag in buddypress.svn.wordpress.org? (y/n)? " answer
	echo ""
	if [ "$answer" != 'y' ]; then
		echo "Are you yaller?"
		exit 1
	fi
	svn ci -m "$commit_message_bump"
else
	echo "DRY RUN: svn ci -m \"$commit_message_bump\""
fi

# Create buddypress.svn.wordpress.org tag.
commit_message_tag="Create tag $ver."
echo "Creating tag."
if [ $dryrun -eq 0 ]; then
	svn cp http://buddypress.svn.wordpress.org/branches/$branch http://buddypress.svn.wordpress.org/tags/$ver -m "$commit_message_tag"
else
	echo "DRY RUN: svn cp http://buddypress.svn.wordpress.org/branches/$branch http://buddypress.svn.wordpress.org/tags/$ver -m \"$commit_message_tag\""
fi

# Build the release.
npm install
grunt build # Not 'release', because we don't want bbPress.

# Get a checkout of plugins.svn trunk.
cd ..

if [ $use_existing_checkouts -eq 0 ]; then
	# Remove existing wporg working directory.
	if [ -d "wporg" ]; then
		rm -rf ./wporg
	fi

	svn co --ignore-externals http://plugins.svn.wordpress.org/buddypress/trunk wporg
fi

# Sync the changes from the bporg checkout to the wporg checkout.
rsync -r --exclude='.svn' bp/src/ wporg/

# Remove bbPress from the checkout and set the external (should already be done, but just in case).
cd wporg
rm -rf bp-forums/bbpress
svn propset svn:externals 'bbpress https://bbpress.svn.wordpress.org/tags/1.2/' bp-forums

# Before committing, roll back the readme, so that the stable tag is not changed.
svn diff readme.txt > ../readme.diff
svn revert readme.txt
svn status

# Commit to trunk.
echo ''
echo "Committing to plugins.svn.wordpress.org trunk."
if [ $dryrun -eq 0 ]; then
	read -n 1 -p "Ready to commit and tag? (y/n)? " answer
	echo ""
	if [ "$answer" != 'y' ]; then
		echo "Boo hoo"
		exit 1
	fi
	svn ci -m "Sync to plugins.svn.wordpress.org for $ver release."
else
	echo "DRY RUN: svn ci -m \"Sync to plugins.svn.wordpress.org for $ver release.\""
fi

# svn cp to the new tag
# Create buddypress.svn.wordpress.org tag.
commit_message_tag="Create tag $ver."
echo "Creating tag."
if [ $dryrun -eq 0 ]; then
	svn cp http://plugins.svn.wordpress.org/buddypress/trunk http://plugins.svn.wordpress.org/buddypress/tags/$ver -m "$commit_message_tag"
else
	echo "DRY RUN: svn cp http://plugins.svn.wordpress.org/buddypres/trunk http://plugins.svn.wordpress.org/tags/$ver -m \"$commit_message_tag\""
fi

# Then bump stable tag in trunk
echo "One more step: Bump the stable tag in readme.txt."
patch -p0 < ../readme.diff

if [ $dryrun -eq 0 ]; then
	read -n 1 -p "Shall I do the honors? (y/n)? " answer
	echo ""
	if [ "$answer" != 'y' ]; then
		echo "Don't forget to do it yourself"
		exit 1
	fi
	svn ci -m "Bump stable tag to $ver."
else
	echo "DRY RUN: svn ci -m \"Bump stable tag to $ver.\""
fi
