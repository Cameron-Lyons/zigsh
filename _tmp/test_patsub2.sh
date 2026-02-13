program='^++--hello.,world<>[]'
program=${program//[^'><+-.,[]']}
echo $program
