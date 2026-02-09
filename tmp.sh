func f(place) {
  var x = 'f'
  echo zzz | read --all (place)
  echo "f x=$x"
}

func fillPlace(place) {
  var x = 'fillPlace'
  call f(place)
  echo "fillPlace x=$x"
}

proc p {
  var x = 'hi'
  call fillPlace(&x)
  echo "p x=$x"
}

x=global

p

echo "global x=$x"
