turtle.getFuelLevel()
turtle.refuel()
while true do
  if turtle.detect() then break end
  -- restock main slots
  for var=12,2,-1 do
    turtle.select(var)
    turtle.transferTo(2)
  end
  -- pipes
  turtle.select(2)
  for var=1,15 do
    turtle.forward()
    turtle.placeUp()
  end
  -- small cogwheels
  turtle.select(1)
  turtle.forward()
  turtle.placeUp()
end
