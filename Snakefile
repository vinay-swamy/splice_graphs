'''
config file:
    sampleFile: tab seperated file  containing sample info
    refFasta_url: link to refernece fastq_path
    salmon_version:
    sratoolkit_version:
notes:
-the 5.2 version requires specifying directorys in output section of rule iwth directory(). Biowulf currently using 5.1
-need to make a rule to download all Gencode refs


01/15/19 Changes
- converted STAR rules into shell from python
- made outputs more organized
- created a synthetic set by sampling 5 samples from all tissues >10 samples, incliding eye tissues, might wanna change that;
    using synthetic set as body set for gtf and rmats
- making mulitple tissue comparisons against the synth for rMATs instead of pair wise comparisons
- restructured outputs so things are a little more organized
- only using paired samples for rmats
- finally got rid of the shitty salmon command
'''
import subprocess as sp

def readSampleFile(samplefile):
    # returns a dictionary of dictionaries where first dict key is sample id and second dict key are sample  properties
    res={}
    with open(samplefile) as file:
        for line in file:
            info=line.strip('\n').split('\t')
            res[info[0]]={'files':info[1].split(','),'paired':True if info[2]=='y' else False, 'tissue':info[3],'subtissue':info[4]}
    return(res)


def tissue_to_gtf(tissue, sample_dict):
    res=[]
    for sample in sample_dict.keys():
        if sample_dict[sample]['tissue']==tissue :
            res.append('st_out/{}.gtf'.format(sample))
    return (res)

def salmon_input(id,sample_dict,fql):
    paired=sample_dict[id]['paired']
    id= fql + 'fastq_files/' + id
    if paired:
        return('-1 {s}_1.fastq.gz -2 {s}_2.fastq.gz'.format(s=id))
    else:
        return('-r {}.fastq.gz'.format(id))

#configfile:'config.yaml'
sample_file=config['sampleFile']
sample_dict=readSampleFile(config['sampleFile'])# sampleID:dict{path,paired,metadata}
tissues=['Adipose.Tissue','Adrenal.Gland','Blood','Blood.Vessel','Brain','Breast','Colon', 'Cornea','Esophagus','Heart',\
'Kidney','Lens','Liver','Lung','Muscle','Nerve','Pancreas','Pituitary','Retina','RPE','Salivary.Gland','Skin','Small.Intestine',\
'Spleen','Stomach','Thyroid','synth']
subtissues=['Adipose.Tissue','Adrenal.Gland','Blood','Blood.Vessel','Brain','Breast','Colon', 'Cornea_Adult.Tissue','Esophagus','Heart',\
'Kidney','Lens_Stem.Cell.Line','Liver','Lung','Muscle','Nerve','Pancreas','Pituitary','Retina_Adult.Tissue','RPE_Adult.Tissue','Salivary.Gland','Skin','Small.Intestine',\
'Spleen','Stomach','Thyroid','synth']
eye_tissues=['Retina','RPE','Cornea','Lens','synth']
sample_names=sample_dict.keys()
loadSRAtk="module load {} && ".format(config['sratoolkit_version'])
loadSalmon= "module load {} &&".format(config['salmon_version'])
salmon_version=config['salmon_version']
STARindex='ref/STARindex'
ref_fasta='ref/gencodeRef.fa'
ref_GTF='ref/gencodeAno.gtf'
ref_GTF_basic='ref/gencodeAno_bsc.gtf'
ref_PA='ref/gencodePA.fa'
fql=config['fastq_path']
stringtie_full_gtf='results/all_tissues.combined.gtf'

rule all:
    input:expand('quant_files/{sampleID}/quant.sf',sampleID=sample_names),\
     'results/combined_stringtie_tx.fa.transdecoder.pep',expand('rmats_out/{tissue}', tissue=subtissues)

'''
****PART 1**** download files and align to genome
-still need to add missing fastq files
-gffread needs indexed fasta
-need to add versioning of tools to yaml
'''
rule downloadGencode:
    output:ref_fasta,ref_GTF_basic,ref_PA
    shell:
        '''

        wget -O ref/gencodeRef.fa.gz {config[refFasta_url]}
        wget -O ref/gencodeAno_bsc.gtf.gz {config[refGTF_basic_url]}
        wget -O ref/gencodePA_tmp.fa.gz {config[refPA_url]}
        gunzip ref/gencodeRef.fa.gz
        gunzip ref/gencodeAno_bsc.gtf.gz
        gunzip ref/gencodePA_tmp.fa.gz
        module load python/3.6
        python3 scripts/filterFasta.py ref/gencodePA_tmp.fa ref/chroms_to_remove ref/gencodePA.fa
        module load samtools
        samtools faidx ref/gencodePA.fa

        '''


rule build_STARindex:
    input: ref_PA, ref_GTF_basic
    output:STARindex
    shell:
        '''
        module load STAR
        mkdir -p ref/STARindex
        STAR --runThreadN 16 --runMode genomeGenerate --genomeDir {output[0]} --genomeFastaFiles {input[0]} --sjdbGTFfile {input[1]} --sjdbOverhang 100

        '''



rule run_STAR_alignment:
    input: fastqs=lambda wildcards: [fql+'fastq_files/{}_1.fastq.gz'.format(wildcards.id),fql+'fastq_files/{}_2.fastq.gz'.format(wildcards.id)] if sample_dict[wildcards.id]['paired'] else fql+'fastq_files/{}.fastq.gz'.format(wildcards.id),
        index=STARindex
    output:temp('STARbams/{id}/raw.Aligned.out.bam'), 'STARbams/{id}/raw.Log.final.out'
    shell:
        '''
        id={wildcards.id}
        mkdir -p STARbams/$id
        module load STAR
        STAR --runThreadN 8 --genomeDir {input.index} --outSAMstrandField intronMotif  --readFilesIn {input.fastqs} \
        --readFilesCommand gunzip -c --outFileNamePrefix STARbams/$id/raw. --outSAMtype BAM Unsorted
        '''

rule sort_bams:
    input:'STARbams/{id}/raw.Aligned.out.bam'
    output:'STARbams/{id}/Aligned.out.bam'
    shell:
        '''
        module load samtools
        samtools sort -o {output[0]} --threads 7 {input[0]}
        '''
'''
****PART 2**** Align with STAR and build Transcriptome
-Reminder that STAR makes the bam even if the alignment fails
-following CHESS paper - run each bam individually through stringtie, then merge to a tissue level, then merge into 1
 use gffcompare at each meerge step;
-12/13/18
    - tried GFFcompare on all samples first gave 300k tx's but salmon couldn't map to them, so will now use
      stringtie merge on a per tissue level, which will cut out a lot of transcripts, then merge with gffcompare.
    - moved gffread > tx into its own rule
-12/14/18
    -st-merge at at it default tpm cut off did nothing, so now going to do what chess ppl did and filter it at 1tpm per tissue

'''


rule run_stringtie:
    input: 'STARbams/{sample}/Aligned.out.bam'
    output:'st_out/{sample}.gtf'
    shell:
        '''
        module load stringtie
        stringtie {input[0]} -o {output[0]} -p 8 -G ref/gencodeAno_bsc.gtf
        '''

#gffread v0.9.12.Linux_x86_64/

rule merge_gtfs_by_tissue:
    input: lambda wildcards: tissue_to_gtf(wildcards.tissue, sample_dict)
    output: 'ref/tissue_gtfs/{tissue}_st.gtf'
    shell:
        '''
        pattern={wildcards.tissue}
        num=$(awk -v pattern="$pattern" '$4==pattern' {sample_file} | wc -l)
        k=3
	    module load stringtie
        stringtie --merge -G ref/gencodeAno_bsc.gtf -l {wildcards.tissue}_MSTRG -F $((num/k)) -T $((num/k)) -o {output[0]} {input}
        '''
rule merge_tissue_gtfs:
    input: expand('ref/tissue_gtfs/{tissue}_st.gtf',tissue=eye_tissues)
    output: stringtie_full_gtf
    shell:
        '''
        mkdir -p ref/gffread_dir
        module load gffcompare
        gffcompare -r ref/gencodeAno_bsc.gtf -o ref/gffread_dir/all_tissues {input}
        mv ref/gffread_dir/all_tissues.combined.gtf {output}
        '''

rule make_tx_fasta:
    input: stringtie_full_gtf
    output: 'results/combined_stringtie_tx.fa'
    shell:
        '''
        ./gffread/gffread -w {output[0]} -g {ref_PA} {input[0]}
        '''

rule run_trans_decoder:
    input:'results/combined_stringtie_tx.fa'
    output:'results/combined_stringtie_tx.fa.transdecoder.pep'
    shell:
        '''
        cd ref
        module load TransDecoder
        TransDecoder.LongOrfs -t {input}
        TransDecoder.Predict --single_best_only -t ../{input}
        mv combined_stringtie_tx.fa.*  results/ || true
        '''

'''
****PART 4**** rMATS
-the rmats shell script double bracket string thing works even though it looks wrong
-updated STAR cmd to match rmats source
- only running paired samples in rMATS
'''

rule rebuild_star_index:
    input: ref_PA, stringtie_full_gtf
    output:'ref/STARindex_stringtie'
    shell:
        '''
        module load STAR
        mkdir -p {output[0]}
        STAR --runThreadN 16 --runMode genomeGenerate --genomeDir {output[0]} --genomeFastaFiles {input[0]} --sjdbGTFfile {input[1]} --sjdbOverhang 100
        '''



rule realign_STAR:
    input: fastqs=lambda wildcards: [fql+'fastq_files/{}_1.fastq.gz'.format(wildcards.id), fql+'fastq_files/{}_2.fastq.gz'.format(wildcards.id)] if sample_dict[wildcards.id]['paired'] else fql + 'fastq_files/{}.fastq.gz'.format(wildcards.id),
        index='ref/STARindex_stringtie',
        gtf=stringtie_full_gtf
    output:'STARbams_realigned/{id}/Aligned.out.bam', 'STARbams_realigned/{id}/Log.final.out'
    shell:
        '''
        id={wildcards.id}
        mkdir -p STARbams_realigned/$id
        module load STAR
        STAR  --outSAMstrandField intronMotif --outSAMtype BAM Unsorted --alignSJDBoverhangMin 6 \
         --alignIntronMax 299999 --runThreadN 8 --genomeDir {input.index} --sjdbGTFfile {input.gtf} \
         --readFilesIn {input.fastqs} --readFilesCommand gunzip -c --outFileNamePrefix STARbams_realigned/$id/
        '''


rule preprMats_running:# this is going to run multiple times, but should not be a problem
    input: expand('STARbams_realigned/{id}/Aligned.out.bam',id=sample_names)
    output:expand('ref/rmats_locs/{tissue}.rmats.txt',tissue=subtissues)
    shell:
        '''
        module load R
        Rscript scripts/preprMATSV2.R {config[sampleFile]}
        '''


rule runrMATS:
    input: 'ref/rmats_locs/{tissue}.rmats.txt','ref/STARindex_stringtie',stringtie_full_gtf
             #,'ref/{tissue1}.rmats.txt','ref/{tissue2}.rmats.txt'
    output: 'rmats_out/{tissue}'
    # might have to change read length to some sort of function
    shell:
        #**need to fix this for bam mode**
        '''
        module load rmats
        rmats --b1 {input[0]} --b2 ref/rmats_locs/synth.rmats.txt  -t paired --readLength 130 --gtf {input[2]} --bi {input[1]} --od {output[0]}
        '''
'''
PART 5 - quantify new transcripts
'''

rule build_salmon_index:
    input:  'results/combined_stringtie_tx.fa'
    output:'ref/salmonindex_st'
    shell:
        '''
        module load {salmon_version}
        salmon index -t {input} --gencode -i {output} --type quasi --perfectHash -k 31'
        '''


rule run_salmon:
    input: fastqs=lambda wildcards: [fql+'fastq_files/{}_1.fastq.gz'.format(wildcards.sampleID),fql+'fastq_files/{}_2.fastq.gz'.format(wildcards.sampleID)] if sample_dict[wildcards.sampleID]['paired'] else fql+'fastq_files/{}.fastq.gz'.format(wildcards.sampleID),
        index='ref/salmonindex_st'
    params: cmd=lambda wildcards: salmon_input(wildcards.sampleID,sample_dict,fql)
    output: 'quant_files/{sampleID}/quant.sf'
    shell:
        '''
        id={wildcards.sampleID}
        module load {salmon_version}
        salmon quant -p 4 -i {input.index} -l A --gcBias --seqBias  {params.cmd} -o quant_files/$id
        '''
