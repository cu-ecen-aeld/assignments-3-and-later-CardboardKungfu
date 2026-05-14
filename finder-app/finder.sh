if [ -d $1 ] # file exists and is a directory
then
    filesdir=$1
else # file either doesn't exist or does but isn't a directory
    echo "1st argument needs to be a valid directory"
    exit 1
fi

if [ -z $2 ]
then
    echo "2nd argument needs to be a valid string"
    exit 1
else
    searchstr=$2
fi

echo "The number of files are $(find "$filesdir" -mindepth 1| wc -l) and the number of matching lines are $(grep -rsho "$searchstr" "$filesdir" | wc -l)"