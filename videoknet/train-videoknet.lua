----------------------------------------------------------------------
-- Massive online trained network on videos
-- load all sort of video, run Clustering learning, online-learn forever
-- January 18th 2013, E. Culurciello with discussion w/ Clement Farabet
--
-- 1. load a video
-- 2. for each few frames: extract patches, cluster-learn filter
-- 3. setup net layer layer, process video through layer, then repeat step 2,3 for all layers
-- 4. periodically check what is learned: test on dataset?
-- 5. enjoy the ultimate net - Yay!
--
----------------------------------------------------------------------

-- TODO: extend k-means to multiple "winners" = average on multiple kernels
-- TODO: create NMaxPool layer: propagate multiple max as winners or average a few of them
-- TODO: group features for pooling
-- TODO: volumetric nn.Tanh, nn.pooling, etc, so we can add more volumeteric layers


require 'nnx'
require 'image'
--require 'kmec'
--require 'unsup'
require 'online-kmeans'
require 'ffmpeg'
require 'trainLayer'

cmd = torch.CmdLine()
cmd:text('Options')
cmd:option('-visualize', true, 'display kernels')
cmd:option('-seed', 1, 'initial random seed')
cmd:option('-threads', 8, 'threads')
cmd:option('-inputsize', 9, 'size of each input patches')
cmd:option('-nkernels', 32, 'number of kernels to learn')
cmd:option('-niter', 15, 'nb of k-means iterations')
cmd:option('-batchsize', 1000, 'batch size for k-means\' inner loop')
cmd:option('-nsamples', 10*1000, 'nb of random training samples')
cmd:option('-initstd', 0.1, 'standard deviation to generate random initial templates')
cmd:option('-statinterval', 5000, 'interval for reporting stats/displaying stuff')
cmd:option('-savedataset', false, 'save modified dataset')
cmd:option('-classify', true, 'run classification train/test')
cmd:option('-nnframes', 4, 'nb of frames uses for temporal learning of features')

cmd:text()
opt = cmd:parse(arg or {}) -- pass parameters to training files:

--if not qt then
--   opt.visualize = false
--end

torch.manualSeed(opt.seed)
torch.setnumthreads(opt.threads)
torch.setdefaulttensortype('torch.DoubleTensor')

is = opt.inputsize
nk1 = opt.nkernels
nnf1 = opt.nnframes

print 'SUPER-NET script!'
----------------------------------------------------------------------
print '==> loading and processing (local-contrast-normalization) of dataset'

--dspath = '/Users/eugenioculurciello/Pictures/2013/1-13-13/VID_20130105_111419.mp4'
--source = ffmpeg.Video{path=dspath, encoding='jpg', fps=24, loaddump=false, load=false}

dspath = '/Users/eugenioculurciello/Desktop/driving1.mp4'
source = ffmpeg.Video{path=dspath, encoding='jpg', fps=24, loaddump=false, load=false}

--dspath = '../datasets/TLD/06_car'
--source = ffmpeg.Video{path=dspath, encoding='jpg', fps=24, loaddump=true, load=false}

--dspath = '../datasets/TLD/08_volkswagen'
--source = ffmpeg.Video{path=dspath, encoding='jpg', fps=24, loaddump=true, load=false}

--dspath = '../datasets/TLD/09_carchase'
--source = ffmpeg.Video{path=dspath, encoding='jpg', fps=24, loaddump=true, load=false}

rawFrame = source:forward()
-- input video params:
ivch = rawFrame:size(1) -- channels
ivhe = rawFrame:size(2) -- height
ivwi = rawFrame:size(3) -- width
source.current = 1 -- rewind video frames

-- number of frames to process:
nfpr = 10 + nnf1 -- batch process size [video frames]

-- normalize and prepare dataset:
neighborhood = image.gaussian1D(9)
normalization = nn.SpatialContrastiveNormalization(ivch, neighborhood, 1e-3)

function createDataBatch()
   trainData = torch.Tensor(nfpr,ivch,ivhe,ivwi)
   for i = 1, nfpr do -- just get a few frames to begin with
      procFrame = normalization:forward(rawFrame) -- full LCN!
      trainData[i] = procFrame
      rawFrame = source:forward()
   end
   return trainData
end

createDataBatch()

----------------------------------------------------------------------
print '==> generating filters for layer 1:'
nlayer = 1
kernels1 = trainLayer(nlayer, trainData, nil, nk1,nnf1,is)

----------------------------------------------------------------------
print '==> create model 1st layer:'

poolsize = 2
cvstepsize = 1
normkernel = image.gaussian1D(7)
ovhe = (ivhe-is+1)/poolsize/cvstepsize -- output video feature height
ovwi = (ivwi-is+1)/poolsize/cvstepsize -- output video feature width

vnet = nn.Sequential()
-- usage: VolumetricConvolution(nInputPlane, nOutputPlane, kT, kW, kH, dT, dW, dH)
vnet:add(nn.VolumetricConvolution(ivch, nk1, nnf1, is, is))
vnet:add(nn.Sum(2))
vnet:add(nn.Tanh())
vnet:add(nn.SpatialLPPooling(nk1, 2, poolsize, poolsize, poolsize, poolsize))
vnet:add(nn.SpatialSubtractiveNormalization(nk1, normkernel))

-- load kernels into network:
kernels1:div(nnf1*nk1*ivch) -- divide kernels so output of SpatialConv is about ~1 or more
vnet.modules[1].weight = kernels1:reshape(nk1,nnf1,is,is):reshape(nk1,1,nnf1,is,is):expand(nk1,ivch,nnf1,is,is)


----------------------------------------------------------------------
print '==> process video throught 1st layer:'

function processLayer1()
   trainData2 = torch.Tensor(nfpr, nk1, ovhe, ovwi)
   for i = nnf1, nfpr do -- just get a few frames to begin with
      procFrames = trainData[{{i-nnf1+1,i},{},{}}]:transpose(1,2) -- swap order of indices here for VolConvolution to work
      trainData2[i] = vnet:forward(procFrames)
      xlua.progress(i, nfpr)
      -- do a live display of the input video and output feature maps 
      wino = image.display{image=trainData[i], win=wino}
      winm = image.display{image=trainData2[i], padding=2, zoom=1, win=winm, nrow=math.floor(math.sqrt(nk1))}
   end
   -- trainData=nil --free memory if needed
end

processLayer1()

--report some statistics:
print('1st layer max: '..vnet.modules[1].output:max()..' and min: '..vnet.modules[1].output:min()..' and mean: '..vnet.modules[1].output:mean())

----------------------------------------------------------------------
print '==> generating filters for layer 2:'
nlayer = 2
nnf2 = 1
nk2 = 64
kernels2 = trainLayer(nlayer,trainData2, nil, nk2,nnf2,is)

----------------------------------------------------------------------
print '==> create model 2nd layer:'

poolsize = 2
cvstepsize = 1
ovhe2 = (ovhe-is+1)/poolsize/cvstepsize -- output video feature height
ovwi2 = (ovwi-is+1)/poolsize/cvstepsize -- output video feature width

vnet2 = nn.Sequential()
vnet2:add(nn.SpatialConvolution(nk1, nk2, is, is))
vnet2:add(nn.Tanh())
vnet2:add(nn.SpatialLPPooling(nk2, 2, poolsize, poolsize, poolsize, poolsize))
vnet2:add(nn.SpatialSubtractiveNormalization(nk2, normkernel))

-- load kernels into network:
kernels2:div(nk2) -- divide kernels so output of SpatialConv is about ~1 or more
vnet2.modules[1].weight = kernels2:reshape(nk2,is,is):reshape(nk2,1,is,is):expand(nk2,nk1,is,is)


----------------------------------------------------------------------
print '==> process video throught 2nd layer:'
print 'Initial frames will be blank because of the VolConv on 1st layer~'

function processLayer2()
   trainData3 = torch.Tensor(nfpr, nk2, ovhe2, ovwi2)
   for i = nnf1, nfpr do -- just get a few frames to begin with
      trainData3[i] = vnet2:forward(trainData2[i])
      xlua.progress(i, nfpr)
      -- do a live display of the input video and output feature maps 
      winm2 = image.display{image=trainData3[i], padding=2, zoom=1, win=winm2, nrow=math.floor(math.sqrt(nk2))}
   end
   -- trainData2=nil --free memory if needed
end

processLayer2()

--report some statistics:
print('2nd layer max: '..vnet2.modules[1].output:max()..' and min: '..vnet2.modules[1].output:min()..' and mean: '..vnet2.modules[1].output:mean())



----------------------------------------------------------------------
----------------------------------------------------------------------
print '==> Now test a few loops of online learning on video'


-- save older kernels to x-check online routines:
kernels1_old = kernels1:clone()
kernels2_old = kernels2:clone()

-- generate more samples:
source.current = source.current - nnf1 -- rewind video
createDataBatch()

-- update kernels with new data:
kernels1 = trainLayer(nlayer, trainData, kernels1, nk1, nnf1, is)
kernels2 = trainLayer(nlayer, trainData2, kernels2, nk2, nnf2, is)

processLayer1()

--report some statistics:
print('1st layer max: '..vnet.modules[1].output:max()..' and min: '..vnet.modules[1].output:min()..' and mean: '..vnet.modules[1].output:mean())

processLayer2()

--report some statistics:
print('2nd layer max: '..vnet2.modules[1].output:max()..' and min: '..vnet2.modules[1].output:min()..' and mean: '..vnet2.modules[1].output:mean())


-- show filters before and after new training:
--image.display{image=kernels1:reshape(nk1,nnf1*is,is), padding=2, symmetric=true,                                            zoom=2, nrow=math.floor(math.sqrt(nk1)), legend='Layer '..nlayer..' filters'}
--image.display{image=kernels1_old:reshape(nk1,nnf1*is,is), padding=2, symmetric=true,                                        zoom=2, nrow=math.floor(math.sqrt(nk1)), legend='Layer '..nlayer..' filters'}
--
--image.display{image=kernels2:reshape(nk2,nnf2*is,is), padding=2, symmetric=true,                                            zoom=2, nrow=math.floor(math.sqrt(nk2)), legend='Layer '..nlayer..' filters'}
--image.display{image=kernels2_old:reshape(nk2,nnf2*is,is), padding=2, symmetric=true,                                        zoom=2, nrow=math.floor(math.sqrt(nk2)), legend='Layer '..nlayer..' filters'}



