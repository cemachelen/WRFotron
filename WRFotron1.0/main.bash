#!/bin/bash
# ------------------------------------------------------------------------------
# WRFOTRON v 1.0
# Christoph Knote (LMU Munich)
# 02/2016
# christoph.knote@lmu.de
# ------------------------------------------------------------------------------
#
## LSF batch script to run an MPI application
#BSUB -P P19010000                  # project code
#BSUB -W 12:00                      # wall clock time 
#BSUB -n __nprocMain__              # number of MPI processors
#BSUB -R "span[ptile=16]"           # number of cores (i.e. 16 x 4 = 64 cores per processor)
#BSUB -J __MAINJOBNAME__            # job name
#BSUB -o __MAINJOBNAME__.%J.out     # output filename
#BSUB -e __MAINJOBNAME__.%J.err     # error filename
#BSUB -q regular                    # queue

#$ -cwd -V                          # execute from current working directory and export all current environment variables to all spawned processes
#$ -l h_rt=04:00:00                 # wall clock time
#$ -pe ib __nprocMain__             # use MPI - number of cores (x4 per processor)

. config.bash

# fix hyper-threading issue with Yellowstone after upgrade
unset MP_PE_AFFINITY
export MP_TASK_AFFINITY=cpu

# -----------------------------------------------------------------------------
# 1) Meteo spinup
# -----------------------------------------------------------------------------

msg "meteo"

# first, do meteo simulation
rm namelist.input

# in case of chemistry its only spinup - for met-only the full duration
if $withChemistry
then
  cp namelist.wrf.prep.spinup namelist.input
else
  cp namelist.wrf.prep.met namelist.input
fi

${mpiCommandMain} ./wrfmeteo.exe

mkdir meteo_out
mv rsl* meteo_out

# vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
# stuff that follows is for runs with chemistry only...
if $withChemistry
then

# from the meteo simulation
rm wrfout*

# -----------------------------------------------------------------------------
# 2) Chemistry simulation
# -----------------------------------------------------------------------------

rm namelist.input
cp namelist.wrf.prep.chem namelist.input

# update restart files with previous results for chemistry, or do cold start

# restart check logic assumes that once we have restart file for domain 1
# we continue, even though further domains might be missing a restart file.
# Logic does not account for the case that restart file for domain 1 is missing,
# but is available for another domain (--> would attempt restart run...)
restartFound=false

for domain in $(seq -f "0%g" 1 ${max_dom})
do

newRunRstFile=wrfrst_d${domain}___inpYear__-__inpMonth__-__inpDay_____inpHour__:00:00
prevRunRstFile=${restartDir}/${newRunRstFile}

if [ -f ${prevRunRstFile} ]
then

msg "substituting initial data with ${prevRunRstFile}"

# listing variables in old (chemistry) and new (met-only) restart files
$ncksBin -m ${prevRunRstFile} | grep -E ': type' | cut -f 1 -d ' ' | sed 's/://' | sort > chemVarList
$ncksBin -m ${newRunRstFile} | grep -E ': type' | cut -f 1 -d ' ' | sed 's/://' | sort  > metVarList

# determining arrays only in old (chemistry) restart file
chemVarsArr=( $(awk 'FNR==NR{a[$0]++;next}!a[$0]' metVarList chemVarList) )
# converting to comma-separated string
chemVarsLst=${chemVarsArr[@]}
chemVarsTxt=${chemVarsLst// /,}

# adding chemistry variables to new restart file
$ncksBin -A -v ${chemVarsTxt} ${prevRunRstFile} ${newRunRstFile}

restartFound=true

fi

done

if ! $restartFound
then

  msg "No file found at ${prevRunRstFile} - cold start"

  rm namelist.input
  cp namelist.wrf.prep.chem_cold namelist.input

fi

msg "chem"

# do the chem run
${mpiCommandMain} ./wrf.exe

mkdir chem_out
mv rsl* chem_out

# -----------------------------------------------------------------------------
# 3) house keeping
# -----------------------------------------------------------------------------

msg "save restart files"

# save restart files in restart directory
for domain in $(seq -f "0%g" 1 ${max_dom})
do
  lastRstFile=wrfrst_d${domain}___endYear__-__endMonth__-__endDay_____endHour__:00:00
  cp ${lastRstFile} ${restartDir}/${lastRstFile}
done

fi
# that stuff was for runs with chemistry only...
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

msg "save output to archive staging area"

# move all new output to archive directory
for domain in $(seq -f "0%g" 1 ${max_dom})
do
  for hour in $(seq -w 1 __fcstTime__)
  do
    curDate=$(date -u --date="__inpYear__-__inpMonth__-__inpDay__ __inpHour__:00:00 ${hour} hours" "+%Y-%m-%d_%H")
    outFile=wrfout_d${domain}_${curDate}:00:00

    cp ${outFile} ${stagingDir}/
  done
done

msg "finished WRF/chem"
