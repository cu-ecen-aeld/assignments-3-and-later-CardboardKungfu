#!/bin/bash

if [ $# -lt 2 ]
then
    echo "Error: Two arguments required."
    echo "Usage: $0 <writefile> <writestr>"
    exit 1
fi

writefile=$1
writestr=$2

dirpath=$(dirname "$writefile")

if ! mkdir -p "$dirpath"
then
    echo "Error: Directory path $dirpath could not be created."
    exit 1
fi

if ! echo "$writestr" > "$writefile"
then
    echo "Error: File $writefile could not be created or written to."
    exit 1
fi