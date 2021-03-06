local tbb   = terralib.includec("tbbexample.h","-I",Rbase.cincludesearchpath['smiscrterra'])
local stdlib = terralib.includec("stdlib.h")
local stdio = terralib.includec("stdio.h")
local unistd = terralib.includec("unistd.h")
local basic_ = terralib.require('basic')
-- terralib.linklibrary("./tbb.so")


function tbb._createCounter(typ)
   local m={}
   m.uint64 = {create= tbb.create_atomic_ull_counter, fetchAndAdd  = tbb.fetch_and_add_atomic_ull_counter,
	fetchAndStore = tbb.fetch_and_store_atomic_ull_counter, get = tbb.get_atomic_ull_counter, free = tbb.free_ull_counter}
   m.int64 = {create= tbb.create_atomic_ll_counter, fetchAndAdd  = tbb.fetch_and_add_atomic_ll_counter,
	fetchAndStore = tbb.fetch_and_store_atomic_ll_counter, get = tbb.get_atomic_ll_counter, free = tbb.free_ll_counter}
   local typname = typ.name
   tbb.AtomicCounters= struct {
      _counter : &opaque;
      create: typ->{&opaque};
      fetchAndAdd: {&opaque,typ}->{typ};
      fetchAndStore: {&opaque,typ}->{typ};
      get: {&opaque}->{typ};
      free: {&opaque}->{};
			    }  
   terra tbb.AtomicCounters:add(r:typ)	return self.fetchAndAdd( self._counter, r)	end
   terra tbb.AtomicCounters:store(r:typ) return self.fetchAndStore( self._counter, r)	end
   terra tbb.AtomicCounters:get()	return self.get( self._counter)			end
   terra tbb.AtomicCounters:free()	return self.free( self._counter)		end
   function tbb.AtomicCounters.metamethods.__typename(self)
      return "AtomicCounters"
   end
   return terra( init: typ)
      var b: tbb.AtomicCounters
      b.create = [m[typname].create]
      b.fetchAndAdd = [ m[typname].fetchAndAdd]
      b.fetchAndStore = [m[typname].fetchAndStore]
      b.get = [ m[typname].get]
      b.free = [m[typname].free]
      b._counter = b.create(init)
      return b
	  end
end
tbb.ULongLongCounter =tbb. _createCounter(uint64)
tbb.LongLongCounter = tbb._createCounter(int64)

local function _papply( input, length, functor,data, grain)
   grain = grain or 100
   functor = functor.tree.expression.value
   local ipass,lpass,gpass=input,length,grain
   local dpass = data or `nil
   local functorRequiredParams = 3
   if data == nil or data.tree.expression.type.name=='niltype' then functorRequiredParams = 2 end
   -- if functorTakesData is true, then the required functor definition has 3 parameters: index,
   -- input,data else the required functor definition has 2 parameters: index, input
   local funcParameters,funcReturn = nil,nil
   for _,x in pairs(functor:getdefinitions())  do
      if #(x:gettype().parameters) == functorRequiredParams then
	 funcParameters, funcReturn = x:gettype().parameters, x:gettype().returntype
	 break
      end
   end
   -- define the actual runner
   -- the runner is a terra function with 4 parameters: index,input, output, data
   -- which ones are needed are determined by funcParameters
   local runnerContents = terralib.newlist()
   local iic,ii,dac,da,idx = symbol("iic"),symbol("ii"),symbol("dac"),symbol("da"),symbol("idx")
   local ooc,oo=symbol('ooc'),symbol('oo')
   -- cast the input array
   runnerContents:insert(quote var [iic] = [funcParameters[2]]([ii]) end)
   if functorRequiredParams==3 then
      -- cast the data object if required
      runnerContents:insert(quote var [dac] = [funcParameters[3]]([da]) end)
   end
   if funcReturn.name=='anon' then
      -- takes idx,input and data, returns nothing    
      if functorRequiredParams==3 then
	 runnerContents:insert(quote functor([idx],[iic],[dac]) end)
      else
	 runnerContents:insert(quote functor([idx],[iic]) end)
      end
   else
      -- retuns something
      runnerContents:insert(quote var [ooc] = @[&&funcReturn]([oo]) end)
      if functorRequiredParams==3 then
      	 runnerContents:insert(quote  [ooc][idx] = functor([idx],[iic],[dac]) end)
      else
      	 runnerContents:insert(quote  [ooc][idx] = functor([idx],[iic]) end)
      end
   end   
   local terra runnerMain([idx]:uint, [ii]:&opaque,[oo]:&&opaque, [da]:&opaque)
      [runnerContents]
   end
   -- define the code that calls tbb with required args
   local pardrive = terralib.newlist()
   local returnValue,input,length,grain = symbol("returnValue"),symbol("input"),symbol("length"), symbol('grain')
   local data2 = symbol('data')
   if not functorRequiredParams ==3 then data2=`nil end
   if funcReturn.name ~= 'anon'  then
      pardrive:insert(quote var [returnValue]  = [&funcReturn]( stdlib.malloc(sizeof(funcReturn)*[length])) end)
      pardrive:insert(quote tbb.apply([&opaque]([input]), [&&opaque](&[returnValue]), [length], [grain], runnerMain, [data2])  end)
      pardrive:insert(quote return([returnValue]) end)
    else
      pardrive:insert(quote tbb.apply([&opaque](input),nil, length, grain, runnerMain, [data2]) end)
    end
    local terra m([input]:&opaque ,[length]:int, [grain]:int,[data2]:&opaque )
       [pardrive]
    end
    return `m(ipass,lpass, gpass, dpass)
end

tbb.papply = macro(_papply)
function tbb.lpapply(arg)
   local input = arg.input or `nil
   local length = arg.length or error("papply needs the length of the input array")
   local functor = arg.functor or error("papply needs the function to apply to the array")
   local data = arg.data or `nil
   local grain = arg.grain or 100
   local terra x()
      var b = tbb.papply(input, length, functor,data, grain)
      return b
   end
   return x()
end
tbb.npar=tbb.lpapply

tbb.examples={}
terra tbb.examples.examplefunctor(index:int, input:&double, data:&tbb.AtomicCounters)
   stdio.printf("%d\n", index)
   data:add(1)
   return index
end
terra tbb.examples.examplefunctor(index:int, input:&double)
   stdio.printf("%d\n", index)
   return index
end
terra tbb.examples.dummy()
   var b= [&double](stdlib.malloc(100))
   var atc = tbb.ULongLongCounter(0)
   var z= tbb.papply(b,12,tbb.examples.examplefunctor,&atc)
   for i=0, 12 do
      stdio.printf("result[%d] = %d\n",i,z[i])
   end
   stdio.printf("atc=%d\n",atc:get())
end
-- tbb.examples.dummy()

terra tbb.examples.examplefunctor2(index:int, input:&&uint8)
   stdio.printf("%d\n", index)
   return input[index]
end
terra tbb.examples.dummy2()
   var b= [&&int8](array("one","two","three","four","five"))
   var atc = tbb.ULongLongCounter(0)
   var z=tbb.papply(b,5,tbb.examples.examplefunctor2,nil,1)
   for i=0, 5 do
      stdio.printf("result[%d] = %s\n",i,z[i])
   end
end
-- tbb.examples.dummy2:printpretty()
-- tbb.examples.dummy2()

-- terra foo(index:int, input:&opaque)
--    stdio.printf("%d\n",index)
-- end
-- local function makeArray(T,n1)
--    local terra make(n:int)
--       var b = [&T](stdlib.malloc(n*sizeof(T)))
--       for i = 0 , n do
-- 	 b[i] = i
--       end
--       return b
--    end
--    return make(n1)
-- end

-- local input = makeArray(double, 10)
-- -- local result = tbb.lpapply{input=input,length=10, functor =tbb.examples.examplefunctor , grain=1 }
-- local result = tbb.npar{length=10, functor =foo , grain=1 }
-- print(result)

return tbb
