# teamboxstats

## What is it?

Simply put, this generates statistics based on recent activities from a Teambox project. 

## How do i use it:

First make sure you have the required gems, i.e.:

    gem install haml gruff optparse httparty

Then to use, try running:

    ruby teamboxstats.rb -u fred -p password teambox

The statistics will be dumped to "out.html" in the current directory.

There are also a few more command-line arguments, i.e.:

    Usage: teamboxstats.rb [options] project
        -u, --user USER                  Username
        -p, --password PASSWORD          Password
        -a, --activities FILE            Read from an activities dump instead of the API
        -c, --conversations FILE         Read from a conversations dump instead of the API
        -t, --tasks FILE                 Read from a tasks dump instead of the API
        -l, --limit LIMIT                How many activities should be retrieved
        -d, --dump                       Dump API lists to activities.json, tasks.json, and conversations.json
        -h, --help                       Display this screen

Have fun!
