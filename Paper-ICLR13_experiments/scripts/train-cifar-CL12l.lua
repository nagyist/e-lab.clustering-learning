----------------------------------------------------------------------
-- Run k-means on CIFAR10 dataset - 1st,2nd layer generation/load and test
----------------------------------------------------------------------

import 'torch'
require 'image'
require 'unsup'

cmd = torch.CmdLine()
cmd:text()
cmd:text('Get k-means templates on directory of images')
cmd:text()
cmd:text('Options')
cmd:option('-visualize', true, 'display kernels')
cmd:option('-seed', 1, 'initial random seed')
cmd:option('-threads', 8, 'threads')
cmd:option('-inputsize', 5, 'size of each input patches')
cmd:option('-nkernels', 64, 'number of kernels to learn')
cmd:option('-niter', 15, 'nb of k-means iterations')
cmd:option('-batchsize', 1000, 'batch size for k-means\' inner loop')
cmd:option('-nsamples', 100*1000, 'nb of random training samples')
cmd:option('-initstd', 0.1, 'standard deviation to generate random initial templates')
cmd:option('-statinterval', 5000, 'interval for reporting stats/displaying stuff')
-- loss:
cmd:option('-loss', 'nll', 'type of loss function to minimize: nll | mse | margin')
-- training:
cmd:option('-save', 'results', 'subdirectory to save/log experiments in')
cmd:option('-plot', true, 'live plot')
cmd:option('-optimization', 'SGD', 'optimization method: SGD | ASGD | CG | LBFGS')
cmd:option('-learningRate', 1e-3, 'learning rate at t=0')
cmd:option('-batchSize', 1, 'mini-batch size (1 = pure stochastic)')
cmd:option('-weightDecay', 0, 'weight decay (SGD only)')
cmd:option('-momentum', 0, 'momentum (SGD only)')
cmd:option('-t0', 1, 'start averaging at t0 (ASGD only), in nb of epochs')
cmd:option('-maxIter', 2, 'maximum nb of iterations for CG and LBFGS')
cmd:text()
opt = cmd:parse(arg or {}) -- pass parameters to training files:

--if not qt then
--   opt.visualize = false
--end

torch.manualSeed(opt.seed)
torch.setnumthreads(opt.threads)
torch.setdefaulttensortype('torch.DoubleTensor')

is = opt.inputsize
nk = opt.nkernels

----------------------------------------------------------------------
-- loading and processing dataset:
dofile '1_data_cifar.lua'


----------------------------------------------------------------------
print '==> extracting patches' -- only extract on Y channel (or R if RGB) -- all ok
data = torch.Tensor(opt.nsamples,is*is)
for i = 1,opt.nsamples do
   img = math.random(1,trainData.data:size(1))
   img2 = trainData.data[img]
   z = math.random(1,trainData.data:size(2))
   x = math.random(1,trainData.data:size(3)-is+1)
   y = math.random(1,trainData.data:size(4)-is+1)
   randompatch = img2[{ {z},{y,y+is-1},{x,x+is-1} }]
   -- normalize patches to 0 mean and 1 std:
   randompatch:add(-randompatch:mean())
   --randompatch:div(randompatch:std())
   data[i] = randompatch
end

-- show a few patches:
if opt.visualize then
   f256S = data[{{1,256}}]:reshape(256,is,is)
   image.display{image=f256S, nrow=16, nrow=16, padding=2, zoom=2, legend='Patches for 1st layer learning'}
end

--if not paths.filep('cifar10-1l.t7') then
   print '==> running k-means'
   function cb (kernels)
      if opt.visualize then
         win = image.display{image=kernels:reshape(nk,is,is), padding=2, symmetric=true, 
         zoom=2, win=win, nrow=math.floor(math.sqrt(nk)), legend='1st layer filters'}
      end
   end                    
   kernels = unsup.kmeans(data, nk, opt.initstd,opt.niter, opt.batchsize,cb,true)
   print('==> saving centroids to disk:')
   torch.save('cifar10-1l.t7', kernels)
--else
--   print '==> loading pre-trained k-means kernels'
--   kernels = torch.load('cifar10-1l.t7')
--end

for i=1,nk do
   -- there is a bug in unpus.kmeans: some kernels come out nan!!!
   -- clear nan kernels   
   if torch.sum(kernels[i]-kernels[i]) ~= 0 then 
      print('Found NaN kernels!') 
      kernels[i] = torch.zeros(kernels[1]:size()) 
   end
   
   -- give gaussian shape if needed:
--   sigma=0.25
--   fil = image.gaussian(is, sigma)
--   kernels[i] = kernels[i]:cmul(fil)
   
   -- normalize kernels to 0 mean and 1 std:
   kernels[i]:add(-kernels[i]:mean())
   kernels[i]:div(kernels[i]:std())
end

print '==> verify filters statistics'
print('filters max mean: ' .. kernels:mean(2):abs():max())
print('filters max standard deviation: ' .. kernels:std(2):abs():max())

----------------------------------------------------------------------
print "==> loading and initialize 1 layer CL model"

o1size = trainData.data:size(3) - is + 1 -- size of spatial conv layer output
cvstepsize = 1
poolsize = 2
l1netoutsize = o1size/poolsize/cvstepsize

l1net = nn.Sequential()
-- 1st layer:
l1net:add(nn.SpatialConvolution(3, nk1, is, is, cvstepsize, cvstepsize))
l1net:add(nn.HardShrink(0.5))
l1net:add(nn.SpatialSubSampling(nk1, poolsize, poolsize, poolsize, poolsize))
l1net:add(nn.SpatialSubtractiveNormalization(nk1, normkernel))
-- 2nd layer:
l1net:add(nn.SpatialConvolutionMap(nn.tables.random(nk1, nk2, 8), is, is))
l1net:add(nn.HardShrink(0.5))
l1net:add(nn.SpatialSubSampling(nk2, poolsize, poolsize, poolsize, poolsize))
l1net:add(nn.SpatialSubtractiveNormalization(nk2, normkernel))

-- initialize 1st layer parameters to learned filters (expand them for use in all channels):
l1net.modules[1].weight = kernels:reshape(nk,1,is,is):expand(nk,3,is,is):type('torch.DoubleTensor')
l1net.modules[1].bias = l1net.modules[1].bias *0

--tests:
--td_1=torch.zeros(3,32,32)
--print(l1net:forward(td_1)[1])

--td_2 = image.lena()
--out_2 = l1net:forward(td_1)
--image.display(out_2)

----------------------------------------------------------------------
print "==> processing dataset with CL network"

trainData2 = {
   data = torch.Tensor(trsize, nk*(l1netoutsize)^2),
   labels = trainData.labels:clone(),
   size = function() return trsize end
}
testData2 = {
   data = torch.Tensor(tesize, nk*(l1netoutsize)^2),
   labels = testData.labels:clone(),
   size = function() return tesize end
}
for t = 1,trainData:size() do
   trainData2.data[t] = l1net:forward(trainData.data[t]:double())
   xlua.progress(t, trainData:size())
end
--trainData2.data = l1net:forward(trainData.data:double())
for t = 1,testData:size() do
   testData2.data[t] = l1net:forward(testData.data[t]:double())
   xlua.progress(t, testData:size())
end
--testData2.data = l1net:forward(testData.data:double())

trainData2.data = trainData2.data:reshape(trsize, nk, l1netoutsize, l1netoutsize)
testData2.data = testData2.data:reshape(tesize, nk, l1netoutsize, l1netoutsize)

-- relocate pointers to new dataset:
--trainData1 = trainData -- save original dataset
--testData1 = testData
trainData = trainData2 -- relocate new dataset
testData = testData2

-- show a few outputs:
if opt.visualize then
   f256S_y = trainData2.data[{ {1,256},1 }]
   image.display{image=f256S_y, nrow=16, nrow=16, padding=2, zoom=2, 
            legend='Output 1st layer: first 256 examples, 1st feature'}
end

print '==> verify statistics'
channels = {'r','g','b'}
for i,channel in ipairs(channels) do
   trainMean = trainData.data[{ {},i }]:mean()
   trainStd = trainData.data[{ {},i }]:std()

   testMean = testData.data[{ {},i }]:mean()
   testStd = testData.data[{ {},i }]:std()

   print('training data, '..channel..'-channel, mean: ' .. trainMean)
   print('training data, '..channel..'-channel, standard deviation: ' .. trainStd)

   print('test data, '..channel..'-channel, mean: ' .. testMean)
   print('test data, '..channel..'-channel, standard deviation: ' .. testStd)
end

--------------------------------------------------------------
--torch.load('c') -- break function
--------------------------------------------------------------


----------------------------------------------------------------------
--print "==> creating 1-layer network classifier"

print "==> creating 2-layer network classifier"
opt.model = '2mlp-classifier'
dofile '2_model.lua' 

print "==> test network output:"
print(model:forward(trainData.data[1]:double()))

dofile '3_loss.lua' 
dofile '4_train.lua'
dofile '5_test.lua'

----------------------------------------------------------------------
print "==> training 1-layer network classifier"

while true do
   train()
   test()
end



-- save datasets:
trainData.data = trainData.data:float()
testData.data = testData.data:float()
torch.save('trainData-cifar-CL1l.t7', trainData)
torch.save('testData-cifar-CL1l.t7', testData)
