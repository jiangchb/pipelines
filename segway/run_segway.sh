#!/bin/sh -e

USAGEMSG="usage: $(basename $0) CONFIGFILE

Starts the segway pipeline given the config file

Author: Fabian Buske

Requirements (modules):
	module fabbus/segway/1.1.0 
	BEDtools (genomeCoverageBed) in path

* CONFIGFILE - the config file describing the joba
* -1 step 1 - collect the bam data from gagri
* -2 step 2 - groom the bam data into bedGraph format
* -3 step 3 - put the data as tracks into a genomedata archive
* -4 step 4 - train the segway model
* -5 step 5 - predict using the segway model
* -6 step 6 - evaluate the output using segtools
* -f force - overwrite existing results
* -a armed - trigger the jobs after writing the scripts
* -v - print progress information (verbose).
"


PIPELINEDIR=`dirname $0`
VERSION="0.0.2"

DO_TRANSFERDATA=""
DO_CONVERTBAM2BEDGRAPH=""
DO_GENERATEARCHIVE=""
DO_TRAINSEGWAY=""
DO_PREDICTSEGWAY=""
DO_EVALUATE=""
CLOBBER=""

ARMED="FALSE"
OVERWRITEALL="FALSE"

[ $# -lt 1 ] && echo "$USAGEMSG" >&2 && exit 1

while getopts "123456afv" opt;
do
    case ${opt} in
        1) DO_TRANSFERDATA="TRUE";;
        2) DO_CONVERTBAM2BEDGRAPH="TRUE";;
        3) DO_GENERATEARCHIVE="TRUE";;
        4) DO_TRAINSEGWAY="TRUE";;
        5) DO_PREDICTSEGWAY="TRUE";;
        6) DO_EVALUATE="TRUE";;
        a) ARMED="TRUE";;
        f) OVERWRITEALL="TRUE";;
        v) VERBOSE="--verbose";;
        \?) print >&2 "$0: error - unrecognized option $1"
        exit 1;;
    esac
done

shift $(($OPTIND-1))
CONFIG=$1

source ${CONFIG}

if [ "$OVERWRITEALL" = "TRUE" ];then
	CLOBBER="--clobber "
fi 

if [ -d ${TARGETDIR}/ ]; then
	echo "[WARN] target directory exists already"
else
	mkdir -p ${TARGETDIR}/
fi

#
# data folder (to put or source the data from)
# Important: add final /
#
SEGWAY_DATA=${TARGETDIR}/data/
SEGWAY_BIN=${TARGETDIR}/bin/
SEGWAY_QOUT=${TARGETDIR}/qout/
SEGWAY_RESULT=${TARGETDIR}/result/
SEGWAY_TRAIN=${SEGWAY_RESULT}/train-${EXPERIMENT}
SEGWAY_PREDICT=${SEGWAY_RESULT}//predict-${EXPERIMENT}

# some housekeeping
mkdir -p $SEGWAY_DATA $SEGWAY_BIN $SEGWAY_QOUT $SEGWAY_RESULT
cp ${REGIONS} ${SEGWAY_DATA}
TRAIN_REGIONS=${SEGWAY_DATA}$(basename ${REGIONS})

##
## collect the data (tracks) from gagri
##
if [ -n "$DO_TRANSFERDATA" ];  then
	# get all files
	echo "echo  'collect data tracks from gagri'" > ${SEGWAY_BIN}/1_cdata.sh
	echo "module load gi/samtools" > ${SEGWAY_BIN}/2_tdata.sh
	while IFS=$'\t' read -r -a DATA; do
       if [[ "${DATA[4]}" =~ ".bam" ]]; then
    	   FILES_SOURCE=${DATA[2]}
    	   for F in $(echo ${DATA[3]} | tr ',' '\n'); do
                echo "echo 'datafile ${F}${DATA[4]}'" >> ${SEGWAY_BIN}/1_cdata.sh
            	echo "[ ! -f ${SEGWAY_DATA}/$F${DATA[4]} ] && smbclient //gagri/diverse -A ~/.smbclient -c 'cd ${FILES_SOURCE}; get ${F}${DATA[4]}' && mv ${F}${DATA[4]} ${SEGWAY_DATA}" >> ${SEGWAY_BIN}/1_cdata.sh
    	        echo "[ ! -f ${SEGWAY_DATA}/$F${DATA[4]}.bai ] && smbclient //gagri/diverse -A ~/.smbclient -c 'cd ${FILES_SOURCE}; get ${F}${DATA[4]}.bai' && mv ${F}${DATA[4]}.bai ${SEGWAY_DATA}" >> ${SEGWAY_BIN}/1_cdata.sh
    	        echo "[ ! -f ${SEGWAY_DATA}/$F${DATA[4]}.bai ] && samtools index ${SEGWAY_DATA}/$F${DATA[4]}" >> ${SEGWAY_BIN}/1_cdata.sh
            done
        fi
    done < $EXPERIMENTS

	chmod 777 ${SEGWAY_BIN}/1_cdata.sh
	if [ $ARMED = "TRUE" ]; then
        ${SEGWAY_BIN}/1_cdata.sh
	fi
fi

##      
## transform the bam data into bedgraph
##
if [ -n "$DO_CONVERTBAM2BEDGRAPH" ]; then
	if [ ! -d ${SEQDIR} ] || [ ! -d ${WIGGLER_UMAPDIR} ]; then
		echo "sequence dir or umap dir is missing/invalid"
		echo "seqDir: ${SEQDIR}"
		echo "umapDIR:${WIGGLER_UMAPDIR}"
		exit 1
	fi
	
	module load gi/bedtools gi/samtools fabbus/wiggler/2.0 	
	echo "module load gi/ucsc_utils/283 gi/samtools fabbus/wiggler/2.0" > ${SEGWAY_BIN}/2_tdata.sh
	echo "module load gi/pigz" > ${SEGWAY_BIN}/2_tdata.sh
	echo "echo 'get chromosome sizes for ${GENOME}'" >> ${SEGWAY_BIN}/2_tdata.sh

	while IFS=$'\t' read -r -a DATA; do
       if [[ "${DATA[4]}" =~ ".bam" ]]; then
            FRAGMENTS=""
            INPUTS=""
            REPNAMES=""
            FILES_SOURCE=${DATA[2]}
            for REPLICA in $(echo ${DATA[3]} | tr ',' '\n'); do
    			[ ! -f ${SEGWAY_DATA}${REPLICA}${DATA[4]} ] && echo "[ERROR] file not found: ${SEGWAY_DATA}${REPLICA}${DATA[4]}" && exit 1
    			INPUTS="${INPUTS} -i=${SEGWAY_DATA}${REPLICA}${DATA[4]}"
            done
            for FRAGSIZE in $(echo ${DATA[5]} | tr ',' '\n'); do
    			FRAGMENTS="${FRAGMENTS} -l=${FRAGSIZE}"
            done
    
    		REPNAMES=${DATA[0]}"_"${DATA[1]}
            echo $REPNAMES
            
        	if [ ! -f ${SEGWAY_DATA}${REPNAMES}.bg.gz ] || [ "$OVERWRITEALL" = "TRUE" ]; then
                [ -f ${SEGWAY_QOUT}TrDa-${REPNAMES}.out ] && rm ${SEGWAY_QOUT}TrDa-${REPNAMES}.out
                echo '#!/bin/bash' > ${SEGWAY_BIN}/tdata${REPNAMES}.sh
                echo 'echo job_id $JOB_ID startdata $(date)' >> ${SEGWAY_BIN}/tdata${REPNAMES}.sh
                echo "echo convert ${REPNAMES} to bedGraph using wiggler" >>  ${SEGWAY_BIN}/tdata${REPNAMES}.sh
                # wiggler
                echo "align2rawsignal -of=bg ${INPUTS} ${FRAGMENTS} -s=${SEQDIR} -u=${WIGGLER_UMAPDIR} -n=5 -v=${SEGWAY_QOUT}wiggler-${REPNAMES}.log -k=tukey -w=${DATA[6]} -o=${SEGWAY_DATA}${REPNAMES}.bg" >> ${SEGWAY_BIN}/tdata${REPNAMES}.sh 
                echo "pigz -9 ${SEGWAY_DATA}${REPNAMES}.bg" >> ${SEGWAY_BIN}/tdata${REPNAMES}.sh  
                echo 'echo job_id $JOB_ID ending $(date)' >> ${SEGWAY_BIN}/tdata${REPNAMES}.sh
                chmod 777 ${SEGWAY_BIN}/tdata${REPNAMES}.sh
                
                # submit
                echo "qsub -pe smp 4 -V -cwd -l h_rt=24:00:00 -j y -m e -S /bin/bash -o ${SEGWAY_QOUT}TrDa-${REPNAMES}.out -N TrDa-${REPNAMES} ${SEGWAY_BIN}/tdata${REPNAMES}.sh" >>  ${SEGWAY_BIN}/2_tdata.sh
            fi
        fi
    done < $EXPERIMENTS

	chmod 777 ${SEGWAY_BIN}/2_tdata.sh
	if [ $ARMED = "TRUE" ]; then
    	${SEGWAY_BIN}/2_tdata.sh
    fi
fi

##
## generate the separate genome archives for the tissues.
## The archieve is then annotated with the bedgraph data  
##
if [ -n "$DO_GENERATEARCHIVE" ]; then

	if [ ! -n "$CHROMSIZES" ];then
		echo "[ERROR] Chromosome sizes not given: $CHROMSIZES"
		exit 1
	fi
	## load module
	module load fabbus/segway/1.1.0
	echo "module load fabbus/segway/1.1.0" > ${SEGWAY_BIN}/3_gdata.sh
	echo "[ -f ${SEGWAY_QOUT}/GnDt-${EXPERIMENT}.out ] && rm ${SEGWAY_QOUT}/GnDt-${EXPERIMENT}.out" >> ${SEGWAY_BIN}/3_gdata.sh

    for CHR in $(cut -f 1 ${CHROMSIZES}); do
        if [ ! -f $SEQDIR/$CHR$FASTASUFFIX ]; then 
            echo "[ERROR] chr file not found: $SEQDIR/$CHR$FASTASUFFIX"
            exit 1
        fi
        echo $SEQDIR/$CHR$FASTASUFFIX
        
    	echo 'echo job_id $JOB_ID startdata $(date)' > ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	# genomedata-load call
    	echo "echo '*** create genomedata archive'"  >> ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	echo "genomedata-load -s $SEQDIR/$CHR$FASTASUFFIX \\" >> ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	# add the -t <ID>=<FILE> sections for all tracks
    	
    	for f in $(ls ${SEGWAY_DATA}*.bg.gz ); do
            b=$(basename $f)
        	arrIN=(${b//./ })
            echo "-t "${arrIN[0]}=$f" \\" >> ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	done
    	echo "${SEGWAY_DATA}${EXPERIMENT}.genomedata" >> ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	echo 'echo job_id $JOB_ID ending $(date)' >> ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	chmod 777 ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh
    	#submit
    	echo "qsub -pe smp 1 -V -cwd -b y -j y -o ${SEGWAY_QOUT}GnDt-${EXPERIMENT}-${CHR}.out -N GnDt-${EXPERIMENT}-${CHR} ${SEGWAY_BIN}/gdata${EXPERIMENT}${CHR}.sh" >> ${SEGWAY_BIN}/3_gdata.sh
    done    
    
	chmod 777  ${SEGWAY_BIN}/3_gdata.sh

	if [ $ARMED = "TRUE" ]; then
        ${SEGWAY_BIN}/3_gdata.sh
	fi
fi

##
## train Seqway models
##
if [ -n "$DO_TRAINSEGWAY" ]; then
	echo "module load fabbus/segway/1.1.0" > ${SEGWAY_BIN}/4_train.sh
    echo "[ -f ${SEGWAY_QOUT}SgTrn-${EXPERIMENT}.out ] && rm ${SEGWAY_QOUT}SgTrn-${EXPERIMENT}.out" >> ${SEGWAY_BIN}/4_train.sh
    echo "[ -d ${SEGWAY_TRAIN} ] && rm -r ${SEGWAY_TRAIN}" >> ${SEGWAY_BIN}/4_train.sh

    OPTIONS="--include-coords=${TRAIN_REGIONS} --num-labels=${LABELS} --num-instances=${INSTANCES} ${CLOBBER} ${SEGWAY_TRAIN_ADDPARAM}"
    echo "echo '*** train segway'" >> ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh
    echo "segway $OPTIONS \\"> ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh 
    
	while IFS=$'\t' read -r -a DATA; do
		REPNAMES=${DATA[0]}"_"${DATA[1]}
        if [[ "${DATA[7]}" == "1" ]]; then
            echo "[USE ] $REPNAMES"
            echo "--track $REPNAMES \\" >> ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh
    	else
    	   echo "[SKIP] $REPNAMES"
		fi
    done < $EXPERIMENTS

    echo "train ${SEGWAY_DATA}${EXPERIMENT}.genomedata ${SEGWAY_TRAIN}" >> ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh

    chmod 777 ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh
    #echo "qsub -l mem_requested=16G -V -cwd -b y -j y -o ${SEGWAY_QOUT}SgTrn0${EXPERIMENT}.out -N SgTrn-${EXPERIMENT} ${SEGWAY_BIN}//segtrain${EXPERIMENT}.sh"  >> ${SEGWAY_BIN}/4_train.sh
    echo "${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh" >> ${SEGWAY_BIN}/4_train.sh
    # make sure there is no douple // in any path as segway doesn't like that
    sed -i 's|//|/|g' ${SEGWAY_BIN}/segtrain${EXPERIMENT}.sh
    
    chmod 777  ${SEGWAY_BIN}/4_train.sh

    if [ $ARMED = "TRUE" ]; then
        ${SEGWAY_BIN}/4_train.sh
    fi
fi

##
## predict using a trained Seqway model
##
if [ -n "$DO_PREDICTSEGWAY" ]; then
	echo "module load fabbus/segway/1.1.0" > ${SEGWAY_BIN}/5_predict.sh
    echo "[ -f ${SEGWAY_QOUT}SgPrd-${EXPERIMENT}.out ] && rm ${SEGWAY_QOUT}SgPrd-${EXPERIMENT}.out" >> ${SEGWAY_BIN}/5_predict.sh
    echo "[ -d ${SEGWAY_PREDICT} ] && rm -r ${SEGWAY_PREDICT}" >> ${SEGWAY_BIN}/5_predict.sh

    echo 'echo job_id $JOB_ID startdata $(date)' > ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh

    echo "echo '*** predict segmentation'" >>  ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    echo "segway --num-labels=${LABELS} ${CLOBBER} \\">> ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    # add the --track <ID> sections
    for f in $(ls ${SEGWAY_DATA}/*.bg ); do
        b=$(basename $f)
        arrIN=(${b//./ })
        echo "--track "${arrIN[0]}" \\" >> ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    done
    echo "identify ${SEGWAY_DATA}${EXPERIMENT}.genomedata ${SEGWAY_TRAIN} ${SEGWAY_PREDICT}" >> ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    echo 'echo job_id $JOB_ID ending $(date)' >> ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    chmod 777 ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh
    # submit
#       echo "qsub -l mem_requested=16G -V -cwd -b y -j y -o ${SEGWAY_QOUT}SgPrd-${EXPERIMENT}.out -N SgPrd-${EXPERIMENT} ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh"   
    echo "${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh" >> ${SEGWAY_BIN}/5_predict.sh
    # make sure there is no douple // in any path as segway doesn't like that
    sed -i 's|//|/|g' ${SEGWAY_BIN}/segpredict${EXPERIMENT}.sh

    chmod 777 ${SEGWAY_BIN}/5_predict.sh
    
    if [ $ARMED = "TRUE" ]; then
        ${SEGWAY_BIN}/5_predict.sh
    fi
fi

##
## Evaluate prediction
##
if [ -n "$DO_EVALUATE" ]; then

	echo "module load fabbus/segway/1.1.0" > ${SEGWAY_BIN}/6_evaluate.sh
    echo 'echo job_id $JOB_ID startdata $(date)' > ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    #preprocess file
    if [ -n $OVERWRITEALL ] || [ ! -f ${SEGWAY_PREDICT}/segway.bed.gz.pkl.gz ]; then
        echo "echo '*** preprocess'" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh     
        echo "segtools-preprocess ${CLOBBER} ${SEGWAY_PREDICT}/segway.bed.gz" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    fi
    
    echo "echo '*** length disttribution analysis'" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    echo "segtools-length-distribution ${SEGWAY_PREDICT}/segway.bed.gz.pkl.gz --outdir=${SEGWAY_RESULT}/length-dist/ ${CLOBBER}" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    
    echo "echo '*** gene aggregation analysis'" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    echo "segtools-aggregation ${SEGWAY_PREDICT}/segway.bed.gz.pkl.gz ${ANNOTATION} --normalize --mode=gene --outdir=${SEGWAY_RESULT}/gencode-agg/ ${CLOBBER}" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    
    echo "echo '*** gmtk parameter generation'" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    echo "segtools-gmtk-parameters ${SEGWAY_TRAIN}/params/params.params --outdir=${SEGWAY_RESULT}/gtmk-param/ ${CLOBBER}" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    
    echo "echo '*** html report generation'" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    echo "cd ${SEGWAY_RESULT}/" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    echo "segtools-html-report -L ${SEGWAY_PREDICT}/segway.layered.bed.gz --results-dir=${SEGWAY_RESULT}/ -o segtools.html ${SEGWAY_PREDICT}/segway.bed.gz.pkl.gz ${CLOBBER}" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    echo "sed 's|${SEGWAY_RESULT}/||g' segtools.html > segtools.html2" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    echo "mv segtools.html2 segtools.html" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    echo "cd $(pwd)" >> ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh 
    
    chmod 777 ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh
    
    echo "qsub -l mem_requested=16G -V -cwd -b y -j y -o ${SEGWAY_QOUT}SgEva-${EXPERIMENT}.out -N SgEva-${EXPERIMENT} ${SEGWAY_BIN}/segeval${EXPERIMENT}.sh" >> ${SEGWAY_BIN}/6_evaluate.sh
    
    chmod 777 ${SEGWAY_BIN}/6_evaluate.sh
    if [ $ARMED = "TRUE" ]; then
        ${SEGWAY_BIN}/6_evaluate.sh
    fi
fi


