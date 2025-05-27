turtle.getFuelLevel()
turtle.refuel()
while true do
  for var=12,2,-1 do
    turtle.select(var)
    turtle.transferTo(2)
  end
  turtle.select(2)
  for var=1,15 do
    turtle.forward()
    turtle.turnRight()
    turtle.place()
    turtle.turnLeft()
  end
  turtle.select(1)
  turtle.forward()
  turtle.turnRight()
  turtle.place()
  turtle.turnLeft()
end
