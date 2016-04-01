#!/usr/bin/env Rscript
#   PFA_VMEM="200000"  # this is used for glm reports, needed for srun
# DT[, c("z","u","v"):=NULL] #remove several columns at once

## The heart of the GLM. Uses the text files of ids generated by the naive method run
# to assign reads to categories and outputs predictions per junction to glmReports. models
# are saved into glmModels for further manual investigation.

########## FUNCTIONS ##########
#library(data.table)
require(data.table)
library(base)
set.seed(1, kind = NULL, normal.kind = NULL)

# allows for variable read length (for trimmed reads)
getOverlapForTrimmed <- function(x, juncMidpoint=150){
    if (as.numeric(x["pos"]) > juncMidpoint){
      overlap = 0
    } else if (as.numeric(x["pos"]) + as.numeric(x["readLen"]) - 1 < juncMidpoint + 1){
      overlap = 0
    } else {
      overlap = min(as.numeric(x["pos"]) + as.numeric(x["readLen"]) - juncMidpoint, 
                    juncMidpoint + 1 - as.numeric(x["pos"]))
    }
  
  return(overlap)
}

processScoreInput <- function(scoreFile){
#print ("WARNING< in process score input, only 1000 reads")

#  scores = fread(scoreFile,header=FALSE, sep="\t")
#   setnames(scores,names(scores),c("id", "pos", "qual", "aScore", "numN", "readLen", "junction"))
  setkey(scores, id)
  
  return(scores)
}

addDerivedFields <- function(dt, useClass){
  if(nrow(dt) > 0){
    # calculate and add on cols for junction overlap, score adjusted for N penalties, 
    ########## now, we have info for read1 and read2 
    dt[,`:=`(is.pos=useClass,overlap=apply(dt, 1, getOverlapForTrimmed), adjScore=aScore+numN)]  # syntax for multiple :=
    # and length-adjusted alignment score (laplace smoothing so alignment score of 0 treated different for different length reads)
    dt[, lenAdjScore:=(adjScore - 0.001)/as.numeric(as.vector(readLen))]
#was     dt[,`:=`(pos=NULL, aScore=NULL, numN=NULL, readLen=NULL, adjScore=NULL)]
  
################# repeat for read2
    ## overlap doesn't make sense for R2 unless it is junctional, not going to model thatdt[,`:=`(is.pos=useClass,overlap=apply(dt, 1, getOverlapForTrimmed), adjScore=aScore+numN)]  # syntax for multiple :=
print ("check if syntax for multiple makes sense")
## therefore, only add length adjusted alignment score for R2 !!
    # and length-adjusted alignment score (laplace smoothing so alignment score of 0 treated different for different length reads)
    dt[, lenAdjScoreR2:=(aScoreR2 - 0.001)/readLenR2]
    dt[,`:=`(pos=NULL, aScoreR2=NULL, numNR2=NULL, readLenR2=NULL, adjScoreR2=NULL, aScore=NULL, numN=NULL, readLen=NULL, adjScore=NULL)]
}
  
  return(dt)
}

# the input file is just the file output by the circularRNApipeline under /ids
processClassInput <- function(classFile,my.names){

############ GILLIAN: when debugging over, pls remove nrows=1000000
#cats = fread(classFile,  sep="\t", nrows=1000000)
cats = fread(classFile,  sep="\t")
print ("IN DEBUGGING MODE")
############################################################

cats=cats

if ( my.names!="none"){
names(cats)=my.names
}
#  cats = data.table(read.delim(classFile,  sep="\t"))

## remove V2 and V3

# old
#  setnames(cats, names(cats), c("id", "R1", "R2", "class"))
  setkey(cats, id)  
  return(cats)
}

# To avoid integer underflow issue when we have too many very small or very large probabilities.
# Take inverse of posterior probability, then take log, which simplifies to sum(log(q) - /sum(log(p))
# and then reverse operations to convert answer back to a probability.
# param p: vector of p values for all reads aligning to junction
# return posterior probability that this is a circular junction based on all reads aligned to it
getPvalByJunction <- function(p ){
  out = tryCatch(
{
  q =  (1-p)
  x = sum(log(q)) - sum(log(p))  # use sum of logs to avoid integer underflow
  return(1/(exp(x) + 1))  # convert back to posterior probability
},
error = function(cond){
  print(cond)
  print(p)
  return("?")
},
warning = function(cond){
  print(cond)
  print(p)
  return("-")
}
  )
return(out)
}

applyToClass <- function(dt, expr) {
  e = substitute(expr)
  dt[,eval(e),by=is.pos]
}

applyToJunction <- function(dt, expr) {
  e = substitute(expr)
  dt[,eval(e),by=junction]
}


#######################################################################
######################## BEGIN JS ADDITION ############################
####################### FIRST JS FUNCTION #############################
########################################################################
################# JS added function to FIT the GLM using arbitrary two-classes

my.glm.model<-function( linear_reads, decoy_reads,use_R2 , max.iter){
### FUNCTION TO FIT GLM TO linear READS, returns the GLM and junction predictions, 
saves = list()  # to hold all of the glms for future use
#max.iter = 2  # number of iterations updating weights and retraining glm

# set up structure to hold per-read predictions
n.neg = nrow(decoy_reads) 
n.pos = nrow(linear_reads)
n.reads = n.neg+n.pos
class.weight = min(n.pos, n.neg)

readPredictions = rbindlist(list(linear_reads, decoy_reads))

# set initial weights uniform for class sum off all weights within any class is equal
if (n.pos >= n.neg){
  readPredictions[,cur_weight:=c(rep(n.neg/n.pos, n.pos), rep(1, n.neg))]
} else {
  readPredictions[,cur_weight:=c(rep(1, n.pos), rep(n.pos/n.neg, n.neg))]
}

# glm
for(i in 1:max.iter){
  # M step: train model based on current read assignments, down-weighting the class with more reasourcds

if (use_R2==1){
  x = glm(is.pos~overlap+lenAdjScore+qual +lenAdjScoreR2 + qualR2, data=readPredictions, family=binomial(link="logit"), weights=readPredictions[,cur_weight])
 # if (1==1){
#    x = glm(is.pos~ as.factor(round(overlap/5))+lenAdjScore+qual +lenAdjScoreR2 + qualR2-1, data=readPredictions, family=binomial(link="logit"))}
}
if (use_R2==0){
  x = glm(is.pos~overlap+lenAdjScore+qual , data=readPredictions, family=binomial(link="logit"), weights=readPredictions[,cur_weight])
}
  saves[[i]] = x

  # get CI on the output probabilities and use 95% CI
  preds = predict(x, type = "link", se.fit = TRUE)
  critval = 1.96 # ~ 95% CI
  upr = preds$fit + (critval * preds$se.fit)
  lwr = preds$fit - (critval * preds$se.fit)
  upr2 = x$family$linkinv(upr)
  lwr2 = x$family$linkinv(lwr)
  
  # use the upper 95% value for decoys and lower 95% for linear
  adj_vals = c(rep(NA, n.reads))
  adj_vals[which(readPredictions$is.pos == 1)] = lwr2[which(readPredictions$is.pos == 1)]
  adj_vals[which(readPredictions$is.pos == 0)] = upr2[which(readPredictions$is.pos == 0)]
  x$fitted.values = adj_vals  # so I don't have to modify below code
  
  # report some info about how we did on the training predictions
  totalerr = sum(abs(readPredictions[,is.pos] - round(x$fitted.values)))
  print (paste(i,"total reads:",n.reads))
  print(paste("both negative",sum(abs(readPredictions[,is.pos]+round(x$fitted.values))==0), "out of ", n.neg))
  print(paste("both positive",sum(abs(readPredictions[,is.pos]+round(x$fitted.values))==2), "out of ", n.pos))
  print(paste("classification errors", totalerr, "out of", n.reads, totalerr/n.reads ))
  print(coef(summary(x)))
  readPredictions[, cur_p:=x$fitted.values] # add this round of predictions to the running totals
  
  # calculate junction probabilities based on current read probabilities and add to junction predictions data.table

  tempDT = applyToJunction(subset(readPredictions, is.pos == 1), getPvalByJunction(cur_p))
  setnames(tempDT, "V1", paste("iter", i, sep="_"))
  setkey(tempDT, junction)
  junctionPredictions = junctionPredictions[tempDT]  # join junction predictions and the new posterior probabilities
  rm(tempDT)  # clean up
  
  # E step: weight the reads according to how confident we are in their classification. Only if we are doing another loop
  if(i < max.iter){
    posScale = class.weight/applyToClass(readPredictions,sum(cur_p))[is.pos == 1,V1]
    negScale = class.weight/(n.neg - applyToClass(readPredictions,sum(cur_p))[is.pos == 0,V1])
    readPredictions[is.pos == 1,cur_weight:=cur_p*posScale]
    readPredictions[is.pos == 0,cur_weight:=((1 - cur_p)*negScale)]
  }
  setnames(readPredictions, "cur_p", paste("iter", i, sep="_")) # update names
}  

# calculate mean and variance for null distribution
## this uses a normal approximation which holds only in cases with large numbers of reads, ie the CLT only holds as the number of reads gets very large

## should be called p-predicted
read_pvals = readPredictions[,max.iter]

## here, want the sampling distribution  
## use linear null instead of read_pvals

#was posteriors = log((1-read_pvals)/read_pvals) 
#posteriors = log((1-null)/null) # note these are quantiles rather than all values 
#use_mu = mean(posteriors)
#use_var=var(posteriors)

# add p-value to junctionPredictions -- read predictions? where is the product in the pnorm
## iter2 is posterior for junctionPredictions



# rename cols to be consistent with circular glmReports, syntax below removes col. "ITER_1"
if (max.iter>1){
for (myi in c(1:(max.iter-1))){
#was junctionPredictions[, iter_1:=NULL]
junctionPredictions[, paste("iter_",myi,sep=""):=NULL]
}
}
print ("before setnames")
print (names(junctionPredictions))
setnames(junctionPredictions, paste("iter_",max.iter,sep=""), "p_predicted")
print ("after setnames")
print (names(junctionPredictions))

#list(saves, junctionPredictions) ## JS these are the outputs and done with function
list(saves, junctionPredictions) ## JS these are the outputs and done with function
}

####################### SECOND JS FUNCTION #############################
########################################################################
###################### prediction from model ##########################
##### as a function, needs input data and model

predictNewClassP <- function(my_reads, null, use.ks){ ## need not be circ_reads, just easier syntax
######### up until this point, every calculation is PER READ, now we want a function to collapse 
######### want to do hypothesis testing 
# calculate junction probabilities based on predicted read probabilities
## Use simple function-- NOTE: "p predicted" is a CI bound not the point estimate. It is still technically a consistent estimate of p predicted 

## formula is a sum over posterior at the log scale: 

## NOTE: p predicted 
## prob of an anomaly by glm is phat/(1+phat) under 'real' 1/(1+phat) under 'decoy' junction, so the ratio of these two reduces to 1/phat. as phat -> 1, no penalty is placed on anomaly.

#merge
junctionPredictions = my_reads[, .N, by = junction] # get number of reads per junction
setnames(junctionPredictions, "N", "numReads")
setkey(junctionPredictions, junction)

my_reads[, logscore:=sum( log ((1/p_predicted)-1) * (1-is.anomaly) + log( 1/p_predicted) *is.anomaly), by=junction]
#junctionPredictions=merge(junctionPredictions,logscore)
#setnames(junctionPredictions, "V1", "logscore")

## is anomaly adjusted log sum scoremm
logsum=my_reads[,sum( log ( p_predicted / (1+p_predicted*is.anomaly))), by=junction]

junctionPredictions=merge(junctionPredictions,logsum)
setnames(junctionPredictions, "V1", "logsum")

print (names(junctionPredictions))

########### adding here
n.quant=2
for (qi in 1:n.quant){
print("TESTNOW diff")
## transform to is.anomaly.
#my_reads[,is.anom.corrected.p_predicted:= p_predicted/(1*is.anomaly + p_predicted) ]
#was my_quantiles =my_reads[,round(10*quantile(p_predicted,probs=c(0:10)/10)[qi])/10,by=junction]

# REVERT old -- no anomaly correction #my_quantiles =my_reads[,round(10*quantile(p_predicted,probs=c(0:10)/10)[qi])/10,by=junction]
my_quantiles = my_reads[,round(10*quantile(p_predicted/(1+is.anomaly* p_predicted),probs=c(0:n.quant)/n.quant)[qi])/10,by=junction]

# merge into junctionPredictions
print (head(my_quantiles))
setkey(my_quantiles,junction)

junctionPredictions=merge(junctionPredictions,my_quantiles)
setnames(junctionPredictions, "V1", paste("q_",qi,sep=""))
}
## add ks.test ps:
use.ks=0
if (use.ks==1){
# random # added since uniform is continuous and ks test can't tolerate ties
myrandom=runif(1,0,.0000001)

my_reads[ , F_of_p :=  ( sum(p_predicted<null))/ length(null)]
# convert F(p_predicted) to qnorm
my_reads[ ,Z_of_p:= qnorm ( (myrandom + F_of_p)/(1+myrandom+is.anomaly* F_of_p))]

## null gives quantiles
print ("adding KS test p values including anomalies and indels")
temp_ks=try(my_reads[,ks.test(Z_of_p,pnorm, alternative="greater")$p,by=junction])
junctionPredictions=merge(junctionPredictions,temp_ks)
setnames(junctionPredictions, "V1", "ks_p_greater")

## alternative
temp_zscore=try(my_reads[,sum(Z_of_p)/sqrt(length(Z_of_p)),by=junction])
junctionPredictions=merge(junctionPredictions,temp_zscore)
setnames(junctionPredictions, "V1", "zscore")

# was temp_ks=my_reads[,ks.test(p_predicted/(1+is.anomaly* p_predicted),null, method="less")$p,by=junction]
#was temp_ks=try(my_reads[,ks.test(F_of_p/(1+is.anomaly* F_of_p),punif, alternative="less")$p,by=junction])

temp_ks=try(my_reads[, ks.test(Z_of_p ,pnorm, alternative="less")$p,by=junction])
junctionPredictions=merge(junctionPredictions,temp_ks)
setnames(junctionPredictions, "V1", "ks_p_less")

}

##################################

##  tempDT, to collapse across junctions 
tempDT = my_reads [ ,eval(substitute( 1/(1+exp(logscore)))),by=junction]
setkey(tempDT, junction)
junctionPredictions = junctionPredictions[tempDT]  # join junction predictions and the new posterior probabilities

 ## don't understand this
junctionPredictions[my_quantiles]

print (head(junctionPredictions[order(junction),]))
setnames(junctionPredictions, "V1", "p_predicted")
## NOTE: P VALUE IS probability of observing a posterior as extreme as it is, "getPvaluebyJunction" is a bayesian posterior

junctionPredictionsWP=assignP(junctionPredictions,null) 
rm(tempDT)  # clean up
## adding here:

unique(junctionPredictionsWP) ## returned

}
########################################################################################### ASSIGN p values through permutation
################################### 
assignP<-function(junctionPredictions,null) {
# logsum is the logged sum
# add p-value to junctionPredictions (see GB supplement with logic for this)
# inputs sum (log(p))
lognull=log(null)

use_mu = mean(lognull) # this is actually the mean of the read level predictions
use_var=var(lognull)
## for large n, 
print ("using threshold of ** below** for p value approximated by ")
n.thresh.exact=5
print (n.thresh.exact)

junctionPredictions[ (numReads>n.thresh.exact) , p_value :=  pnorm((logsum - numReads*use_mu)/sqrt(numReads*use_var))]
## make empirical distribution of posteriors:

print ("exact calculation through sampling 10K p predicted")
my.dist=list(n.thresh.exact)
for ( tempN in 1:n.thresh.exact){
n.sampled=1000 # used to compute the null distribution of posteriors
#hist(read_phat)

my.dist[[tempN]]=sample(lognull, n.sampled, replace=T)
}
for ( tempN in 1:n.thresh.exact){ ## use this loop to assign jncts w/ tempN
sim.readps=my.dist[[1]]
#print (quantile(sim.readps, probs=c(0:100)/100))
if (tempN>1){
for (tj in 2: tempN){ # loop, taking products
sim.readps=my.dist[[tj]] +  sim.readps
}
}
## PRINT: START DEBUGG!! 
# convert to posterior
## fraction of time p_predicted is smaller than -- so if p_predicted is very large, the fraction of time it is smaller is big
junctionPredictions [ (numReads == tempN ), p_value:= sum( (1/(1+exp(sim.readps)))<p_predicted)/length(1/(1+exp(sim.readps)))]

#print (head(junctionPredictions))
print (head(sim.readps))
}
return(junctionPredictions)
}
###########################################################################################
###########################################################################################
###########################################################################################
###########################################################################################
######## END FUNCTIONS, BEGIN WORK #########

## command line inputs
user.input=1
if (user.input==1){
args = commandArgs(trailingOnly = TRUE)
fusion_class_input=args[1]
class_input=args[2]
srr= args[3]
output_dir=args[4]
reg_indel_class_input = args[5]
FJ_indel_class_input = args[6]
## should be:
#FJ_indel_class_input = paste(parentdir,srr,"_output_FJIndels.txt",sep="")
#reg_indel_class_input = paste(parentdir,srr,"_output_RegIndel.txt",sep="")
}

max.iter=2 ## iterations for glm

## ONLYY FOR DEBUGGING
if (user.input==0){
  output_dir=""}

use.indels=1
use.fusion=1

if (user.input==0){ ## THIS IF LOOP ONLY if we want to bypass command line inputs!

use.normal.breast=1
use.cml=0
use.ews=0

## GILLIAN
if (use.cml==1){
parentdir=""
srr="ENCFF000HOC1"

parentdir="/scratch/PI/horence/gillian/CML_test/aligned/CML/circReads/ids/"
fusion_class_input = paste(parentdir,srr,"_1__output_FJ.txt",sep="")
class_input = paste(parentdir,srr,"_1__output.txt",sep="")

FJ_indel_class_input = paste(parentdir,srr,"_output_FJIndels.txt",sep="")
reg_indel_class_input = paste(parentdir,srr,"_output_RegIndel.txt",sep="")
output_dir=""


sampletest="CML1"

#srr="ENCFF000HOC2"
#fusion_class_input = "/scratch/PI/horence/gillian/CML_test/aligned/CML/circReads/ids/ENCFF000HOC2_1__output_FJ.txt"
#class_input="/scratch/PI/horence/gillian/CML_test/aligned/CML/circReads/ids/ENCFF000HOC2_1__output.txt"
#sampletest="CML2"
}
if (use.ews==1){
srr="SRR1594025" #
#srr="SRR1594023"
parentdir="/scratch/PI/horence/gillian/Ewing/circpipe/circReads/ids/"
fusion_class_input = paste(parentdir,srr,"_1__output_FJ.txt",sep="")
class_input = paste(parentdir,srr,"_1__output.txt",sep="")

FJ_indel_class_input = paste(parentdir,srr,"_output_FJIndels.txt",sep="")
reg_indel_class_input = paste(parentdir,srr,"_output_RegIndel.txt",sep="")
output_dir=""

output_dir=""
sampletest=paste("ews_",srr,sep="")

}

########## Gillian, note the 'indels vs indel' in the normal breast names and the 'no 1' ######################
if (use.normal.breast==1){
parentdir="/scratch/PI/horence/gillian/normal_breast/circpipe/circReads/ids/"
srr="SRR1027190"
class_input = paste(parentdir,srr,"_1__output.txt",sep="")
fusion_class_input = paste(parentdir,srr,"_1__output_FJ.txt",sep="")
FJ_indel_class_input = paste(parentdir,srr,"_output_FJIndels.txt",sep="")
reg_indel_class_input = paste(parentdir,srr,"_output_RegIndel.txt",sep="")
output_dir=""
sampletest=paste("normal_breast_windel_",srr,sep="")
}
}

## define output class files
glm_out = paste(output_dir,srr,"_DATAOUT",sep="")
anomaly_glm_out = paste(output_dir,srr,"_AnomalyDATAOUT",sep="")
indel_glm_out = paste(output_dir,srr,"_IndelDATAOUT",sep="")
linear_juncp_out = paste(output_dir,srr,"_LINEARJUNCP_OUT",sep="")
circ_juncp_out = paste(output_dir,srr,"_CIRC_JUNCP_OUT",sep="")
fusion_juncp_out = paste(output_dir,srr,"_FUSION_JUNCP_OUT",sep="")
linearwanomaly_juncp_out = paste(output_dir,srr,"_LINEAR_W_ANOMALY_JUNCP_OUT",sep="")
fusionwanomaly_juncp_out= paste(output_dir,srr,"_FUSION_W_ANOM_JUNCPOUT", sep="")
fusionwanomaly_and_indel_juncp_out= paste(output_dir,srr,"_FUSION_W_ANOM_AND_INDEL_JUNCPOUT", sep="")
####### CURRENT GOAL IS TO UPDATE LINEAR pvalues w/ anomaly reads
linear_juncp_update_out = paste(output_dir,srr,"_LINEARJUNCP_UPDATED_OUT",sep="")
##### SINK THE SUMMARY OF THIS SCRIPT
#sink(paste(output_dir,srr,"_glmInformation_",sep=""))

### DONE W/ LOOP


my.names="none" ## this is bc Gillians fields are not names like Lindas are
myClasses = processClassInput(class_input, my.names)

if (use.fusion==1){
print (paste("using ", fusion_class_input))
myClassesFusion = processClassInput(fusion_class_input,names(myClasses))
}
if (use.indels==1){
print (paste("using ", reg_indel_class_input," and " , FJ_indel_class_input))
myClassesRegIndel = processClassInput(reg_indel_class_input,names(myClasses))
myClassesFJIndel = processClassInput(FJ_indel_class_input,names(myClasses))
}

print(paste("class info processed", dim(myClasses)))

circ_reads = myClasses[(class %like% 'circ'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
circ_reads = addDerivedFields(circ_reads, 1)
circ_reads [, is.anomaly:=0] ## this is not an anomaly type so WILL NOT have p value ajustment

print ("finished circ_reads")

decoy_reads = myClasses[(class %like% 'decoy'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
decoy_reads = addDerivedFields(decoy_reads, 0)
decoy_reads [, is.anomaly:=1] ######## this IS an anomaly type 

print ("finished decoy_reads")
## was
linear_reads = myClasses[(class %like% 'linear'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
linear_reads = addDerivedFields(linear_reads, 1)
linear_reads [, is.anomaly:=0] ## this is not an anomaly type so WILL NOT have p value ajustment

print ("finished linear_reads")

anomaly_reads = myClasses[(class %like% 'anomaly'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
anomaly_reads [, is.anomaly:=1]
print ("finished anomaly_reads")

if (use.indels==1){
## in analogy, we first define all indels, then assign good and bad
## we will use anomaly field as a general term for 'anomaly mapping and indel'
reg_indel_reads = myClassesRegIndel[, list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
reg_indel_reads [, is.anomaly:=1]
print ("Finished reg indels")

FJ_indel_reads = myClassesFJIndel[, list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]
FJ_indel_reads [, is.anomaly:=1]
FJ_indel_reads = addDerivedFields(FJ_indel_reads, 1)
print ("Finished FJ indels")
}

if (use.fusion==1){

#was na.omit
fusion_reads = (myClassesFusion[(class %like% 'FJgood'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),])
fusion_reads = addDerivedFields(fusion_reads, 1)
fusion_reads [, is.anomaly:=0] ## this is not an anomaly type so WILL NOT have p value ajustment

print ("ANOMALY fusions defined as FJ bad-- of any variety")
anomaly_fusion_reads = (myClassesFusion[(class %like% 'FJbad'), list(id, pos, qual, aScore, numN, readLen, junction, qualR2,aScoreR2, numNR2, readLenR2),]) # GILLIAN, pls comment here on what FJ bad is for the sake of documentation

anomaly_fusion_reads = addDerivedFields(anomaly_fusion_reads, 1)
anomaly_fusion_reads [, is.anomaly:=1] ## this is not an anomaly type so WILL NOT have p value ajustment
}
###############################################################################################
## CANNOT ADD DERIVED FIELDS HERE BECAUSE WE DON'T KNOW WHICH ANOMALIES ARE GOOD AND/OR BAD
##################### DERIVED FIELDS ADDED LATER ##############################################
###############################################################################################

# set up data structure to hold per-junction predictions
junctionPredictions = linear_reads[, .N, by = junction] # get number of reads per junction
setnames(junctionPredictions, "N", "numReads")
setkey(junctionPredictions, junction)

#### TRAIN EM ####
## this should be a function of any two classes; and the output will be the model

## 
print ("not using all data only 3 parameters")
n.row= dim(linear_reads)[1]
n.sample=min(n.row,10000) 
#linear_reads[,p_predicted:=NULL]
#decoy_reads[,p_predicted:=NULL]
print ("calling linear decoy model")
linearDecoyGLMoutput = my.glm.model ( linear_reads[ sample(n.row,n.sample,replace=FALSE),], decoy_reads, 1, max.iter) ## 0 does not use R2 info JS these are the outputs and done with function

saves = linearDecoyGLMoutput[[1]]
linearJunctionPredictions =  linearDecoyGLMoutput[[2]]
save(saves, file=glm_out)  # save models
linearDecoyGLM = saves[[max.iter]] ##### this is the glm model

## after fitting the GLM to linear vs. decoy, we want to store linear junction predictions in order to subset anomalies
######## JS ADDITION: NOTE- NOT stratifying on permutation p value, although could add this too

pGoodThresh=.8
good.linear=linearJunctionPredictions[p_predicted> pGoodThresh,]
pBadThresh=.2
bad.linear=linearJunctionPredictions[p_predicted< pBadThresh,]

# define two classes of anomalies: those from good vs. bad junctions
good_anomaly_reads= anomaly_reads[!is.na(match(junction, good.linear$junction)),]
bad_anomaly_reads= anomaly_reads[!is.na(match(junction, bad.linear$junction)),]
## NOW add derived fields, 3.19
#good_anomaly_reads = addDerivedFields(good_anomaly_reads, 1)
#bad_anomaly_reads = addDerivedFields(bad_anomaly_reads, 0)


if (use.indels==1){
# define two classes of regular INDELS for training: those from good vs. bad junctions
good_indel_reads= reg_indel_reads[!is.na(match(junction, good.linear$junction)),]
bad_indel_reads= reg_indel_reads[!is.na(match(junction, bad.linear$junction)),]
#good_indel_reads = addDerivedFields(good_indel_reads, 1)
#bad_indel_reads = addDerivedFields(bad_indel_reads, 0)
}

##### now, re-run script training on anomalies from good vs. bad

## The "1" belowneeds to be 0 and 1 for good and bad anomalies
good_anomaly_reads = addDerivedFields(good_anomaly_reads, 1) #### WHAT IS CLASS or derived fields???
bad_anomaly_reads = addDerivedFields(bad_anomaly_reads, 0) #### WHAT IS CLASS or derived fields???
all_anomaly_reads=rbind(good_anomaly_reads,bad_anomaly_reads)

## in anaolgy, same for INDELS
if (use.indels==1){
good_indel_reads = addDerivedFields(good_indel_reads, 1) #### WHAT IS CLASS or derived fields???
bad_indel_reads = addDerivedFields(bad_indel_reads, 0) #### WHAT IS CLASS or derived fields???
all_indel_reads=rbind(good_indel_reads,bad_indel_reads)
}
######## now, RECALL GLM  FOR ANOMALY READ MAPPERS
print ("calling good anomaly bad anomaly model with .8 and .2 as thresholds")
AnomInfo = my.glm.model (good_anomaly_reads, bad_anomaly_reads,1, max.iter) ## JS these are the outputs and done with function
ANOMALYsaves=AnomInfo[[1]]
ANOMALYjunctionPredictions=AnomInfo[[2]]
AnomalyGLM = ANOMALYsaves[[max.iter]] ##### this is the glm model

if (use.indels==1){
print ("calling INDEL model with .8 and .2 as thresholds")
IndelInfo = my.glm.model (good_indel_reads, bad_indel_reads,1, max.iter) ## JS these are the outputs and done with function
INDELsaves=IndelInfo[[1]]
INDELjunctionPredictions=IndelInfo[[2]]
IndelGLM = INDELsaves[[max.iter]] ##### this is the glm model
}

## save GLMS
save(AnomalyGLM, file=anomaly_glm_out)  # save models
if (use.indels==1){
save(IndelGLM, file=indel_glm_out)  # save models
}
save(linearDecoyGLM, file=glm_out)  # save models

################################################################################ BEGIN IN PROGRESS
### START LINEARS
################# predict on anomaly reads -- AND TEST HOW THIS IMPACTS LINEAR PREDICTIONS
############################ linear predictions ONLY ON THE BASIS of anomalies...
print ("RECYCLING data-- not valid----- COULD SUBAMPLE, also, NEED TO SIMPLY ADD PREDICTORS and data to list")

preds = predict(linearDecoyGLM, newdata=linear_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
linear_reads[, p_predicted:= linearDecoyGLM$family$linkinv(lwr)] # add lower 95% CI prediction

preds = predict(linearDecoyGLM, newdata=decoy_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
decoy_reads[, p_predicted:= linearDecoyGLM$family$linkinv(lwr)] # add lower 95% CI prediction


preds = predict(AnomalyGLM, newdata=all_anomaly_reads, type = "link", se.fit = TRUE) 

lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
all_anomaly_reads[, p_predicted:= AnomalyGLM$family$linkinv(lwr)] # add lower 95% CI prediction
## need to rbind anomaly junctions 
linear_and_anomaly=rbind(all_anomaly_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)], linear_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)])




## for null
print ("Assigning null distribution for all linear reads")

null=linear_and_anomaly$p_predicted/(1+linear_and_anomaly$is.anomaly*linear_and_anomaly$p_predicted)

#null=linear_reads$p_predicted

linearWithAnomalyJunctionPredictions = predictNewClassP(linear_and_anomaly, null, use.ks=0)

################# DONE WITH LINEARS
#########################################################################

#### PREDICT CIRCULAR JUNCTIONS #### SHOULD MAKE THIS MODULAR AND A FUNCTION so Farjunction and Anomalies can be used
## SIMPLE PREDICT ON CIRCLES
preds = predict(linearDecoyGLM, newdata=circ_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
circ_reads[, p_predicted:= linearDecoyGLM$family$linkinv(lwr)] # add lower 95% CI prediction
circularJunctionPredictions = predictNewClassP(circ_reads, null, use.ks=1)

#########################################################################
## start fusions ############################################################################
############################################################################
################# NOTE: Here, we are only using fusion reads not fusion anomaly reads and treating the prediction just like circle
############################################################################
############################################################################
## start prediction on good far junctions

if (use.fusion==1){
fusion_reads$overlap=as.numeric(as.vector(fusion_reads$overlap))
preds = predict(linearDecoyGLM, newdata=fusion_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
fusion_reads[, p_predicted:= linearDecoyGLM$family$linkinv(lwr)] # add lower 95% CI prediction
fusionJunctionPredictions = predictNewClassP( fusion_reads, null, use.ks=1)


# start prediction on BAD=Anomaly mapping
print ("done with fusion normals, starting anomalies")

preds = predict(AnomalyGLM, newdata=anomaly_fusion_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
anomaly_fusion_reads[, p_predicted:= AnomalyGLM$family$linkinv(lwr)] # add lower 95% CI prediction
linear_and_anomaly_fusions=rbind(anomaly_fusion_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)], fusion_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)])
linear_and_anomaly_fusions$overlap=as.numeric(as.vector(linear_and_anomaly_fusions$overlap))
linearWithAnomalyFusionPredictions = predictNewClassP(linear_and_anomaly_fusions, null, use.ks=1)

# start prediction on INDELS mapping
print ("done with fusion anomalies starting indels")
if (use.indels==1){

FJ_indel_reads$overlap=as.numeric(as.vector(FJ_indel_reads$overlap))
use.indel.fit=0
if (use.indel.fit==1){
preds = predict(IndelGLM, newdata=FJ_indel_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
FJ_indel_reads[, p_predicted:= IndelGLM$family$linkinv(lwr)] # add lower 95% CI prediction
}
if (use.indel.fit==0){
preds = predict(AnomalyGLM, newdata=FJ_indel_reads, type = "link", se.fit = TRUE) 
lwr = preds$fit - (1.96 * preds$se.fit)  # ~ lower 95% CI to be conservative 
FJ_indel_reads[, p_predicted:= AnomalyGLM$family$linkinv(lwr)] # add lower 95% CI prediction
}
}

print ("worked to get FJ predictions")
if (use.indels==1){
linear_and_anomaly_and_indel_fusions=rbind(FJ_indel_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)],anomaly_fusion_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)], fusion_reads[,list(qual,lenAdjScore,qualR2,lenAdjScoreR2,junction,is.pos,overlap,is.anomaly,p_predicted)])
linear_and_anomaly_and_indel_fusions$overlap=as.numeric(as.vector(linear_and_anomaly_and_indel_fusions$overlap))
print("GILLIAN AND JS doublecheck that this works: note the above should just give us p-predicteds and now newclassP will aggregate to junction-level")
print ("GILLIAN and JS- check why overlap needs to be assigned a numerical variable-- is it text?")
linearWithAnomalyAndIndelFusionPredictions = predictNewClassP(linear_and_anomaly_and_indel_fusions, null, use.ks=1)
}

print ("CURRENTLY NEED TO JOIN THESE TABLES")
consolidated_fusion=merge(fusionJunctionPredictions,linearWithAnomalyFusionPredictions , all=TRUE,by="junction")
consolidated_fusion[,p_diff:=(p_predicted.x-p_predicted.y)] ## p_predicted.x should be less than p_predicted.y always so p_diff should be neegative
consolidated_fusion=data.table(unique(consolidated_fusion))

write.table(unique(fusionJunctionPredictions[order(-p_predicted),]),fusion_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")
write.table(unique(consolidated_fusion)[order(-p_predicted.y),], fusionwanomaly_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")
####### now add indels
if (use.indels==1){
print ("now adding indels")
consolidated_fusion_windel=merge(linearWithAnomalyFusionPredictions ,linearWithAnomalyAndIndelFusionPredictions, all=TRUE,by="junction")
consolidated_fusion_windel[,p_diff_indel:=(p_predicted.y-p_predicted.x)] ## p_predicted.x should be less than p_predicted.y always so p_diff should be neegative
consolidated_fusion_windel=data.table(unique(consolidated_fusion_windel))
write.table(unique(consolidated_fusion_windel)[order(-p_predicted.y),], fusionwanomaly_and_indel_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")
}
}
####################################################################################
####################################################################################

## write circle prediction
write.table(unique(linearJunctionPredictions), linear_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")
write.table(unique(circularJunctionPredictions), circ_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")

## with anomalies, p value should be smaller so p_diff should always be negative...
consolidated_linear=merge(linearWithAnomalyJunctionPredictions,linearJunctionPredictions,by="junction",all=TRUE) 
consolidated_linear[,p_diff:=(p_predicted.x-p_predicted.y)] ## p_predicted.x should be less than p_predicted.y always so p_diff should be neegative
consolidated_linear=data.table(unique(consolidated_linear))
write.table(unique(consolidated_linear), linearwanomaly_juncp_out, row.names=FALSE, quote=FALSE, sep="\t")

## 
my.null.quantiles=quantile(linear_reads$p_predicted,probs=c(0:10)/10)
## refer fusions to these quantiles; 'falsely called' vs. true will be fraction of linears (conservative estimate) ; error at this quantile can be evaluated. 


#finish up by computing decoy distributions decoys
