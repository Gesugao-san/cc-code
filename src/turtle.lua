turtle.getFuelLevel()
turtle.refuel()
while true do
  for var=19,2,-1 do
    select(var)
    turtle.transferTo(2)
  end
  select(2)
  for var=1,16 do
    turtle.forward()
    turtle.turnRight()
    turtle.place()
    turtle.turnLeft()
  end
  select(1)
  turtle.forward()
  turtle.turnRight()
  turtle.place()
  turtle.turnLeft()
end
