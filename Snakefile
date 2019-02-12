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
#sample information
sample_file=config['sampleFile']
sample_dict=readSampleFile(config['sampleFile'])# sampleID:dict{path,paired,metadata}
tissue_file=config['tissueFile']
subtissue_file=config['subtissueFile']
with open(tissue_file) as tf, open(subtissue_file) as sf:
    tissues= [line.strip('\n') for line in tf]
    subtissues= [line.strip('\n') for line in sf]
sample_names=sample_dict.keys()
rmats_events=['SE','RI','MXE','A5SS','A3SS']
#software version info
salmon_version=config['salmon_version']
stringtie_version=config['stringtie_version']
STAR_version=config['STAR_version']
rmats_version=config['rmats_verson']
R_version=config['R_version']
TransDecoder_version=config['TransDecoder_version']
samtools_version=config['samtools_version']
gffcompare_version=config['gffcompare_version']
hmmer_version=config['hmmer_version']
crossmap_version=config['crossmap_version']
#commonly used files
STARindex='ref/STARindex'
ref_fasta='ref/gencodeRef.fa'
ref_GTF='ref/gencodeAno.gtf'
ref_GTF_basic='ref/gencodeAno_bsc.gtf'
ref_PA='ref/gencodePA.fa'
fql=config['fastq_path']
stringtie_full_gtf='results/all_tissues.combined.gtf'
chain_file=config['chain_file']
rule all:
    input:expand('quant_files/{sampleID}/quant.sf',sampleID=sample_names),\
     'results/stringtie_alltissues_cds_b37.gff3','results/hmmer/domain_hits.tsv',\
     expand('results/complete_rmats_output/all_tissues.{event}.incLevel.tsv', event=rmats_events)

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
        module load {samtools_version}
        samtools faidx ref/gencodePA.fa

        '''


rule build_STARindex:
    input: ref_PA, ref_GTF_basic
    output:STARindex
    shell:
        '''
        module load {STAR_version}
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
        module load {STAR_version}
        STAR --runThreadN 8 --genomeDir {input.index} --outSAMstrandField intronMotif  --readFilesIn {input.fastqs} \
        --readFilesCommand gunzip -c --outFileNamePrefix STARbams/$id/raw. --outSAMtype BAM Unsorted
        '''

rule sort_bams:
    input:'STARbams/{id}/raw.Aligned.out.bam'
    output:'STARbams/{id}/Aligned.out.bam'
    shell:
        '''
        module load {samtools_version}
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
-01/22/19
    - use gffcompare gtf not stringtie-merge gtf because gffcompare is significantly better than stringtie at mapping
    back to genes. GFFcompare found 20K novel tx vs 18K on st-merge, with the same number of transcript.
    - at the initial merge step with stringtie, filteing out transcripts with at least 1 tpm in a third of the samples

'''


rule run_stringtie:
    input: 'STARbams/{sample}/Aligned.out.bam'
    output:'st_out/{sample}.gtf'
    shell:
        '''
        module load {stringtie_version}
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
	    module load {stringtie_version}
        stringtie --merge -G ref/gencodeAno_bsc.gtf -l {wildcards.tissue}_MSTRG -F $((num/k)) -T $((num/k)) -o {output[0]} {input}
        '''
rule merge_tissue_gtfs:
    input: expand('ref/tissue_gtfs/{tissue}_st.gtf',tissue=tissues)
    output: stringtie_full_gtf, 'results/all_tissues.stringtie_merge.gtf'
    shell:
        '''
        module load {stringtie_version}
        stringtie --merge -G ref/gencodeAno_bsc.gtf  -o {output[1]} {input}
        mkdir -p ref/gffread_dir
        module load {gffcompare_version}
        gffcompare -r ref/gencodeAno_bsc.gtf -o ref/gffread_dir/all_tissues {input}
        module load {R_version}
        Rscript scripts/fix_gene_id.R ref/gffread_dir/all_tissues.combined.gtf {output[0]}
        '''
#gffread v0.9.12.Linux_x86_64/
rule make_tx_fasta:
    input: stringtie_full_gtf
    output: 'results/combined_stringtie_tx.fa'
    shell:
        '''
        ./gffread/gffread -w {output[0]} -g {ref_PA} {input[0]}
        '''

rule run_trans_decoder:
    input:'results/combined_stringtie_tx.fa'
    output:'results/transdecoder_results/combined_stringtie_tx.fa.transdecoder.gff3', \
    'results/transdecoder_results/combined_stringtie_tx.fa.transdecoder.pep'
    shell:
        '''
        cd ref
        module load {TransDecoder_version}
        TransDecoder.LongOrfs -t ../{input}
        TransDecoder.Predict --single_best_only -t ../{input}
        mv combined_stringtie_tx.fa.transdecoder.*  ../results/transdecoder_results/
        '''
rule clean_pep:
    input:'results/transdecoder_results/combined_stringtie_tx.fa.transdecoder.pep'
    output:'results/best_orfs.transdecoder.pep', 'ref/pep_fasta_meta_info.tsv'
    shell:
        '''
        python3 clean_pep.py {input} {output}
        '''
rule build_pfm_hmmDB:
    params: url=config['pfam_db']
    output:'ref/hmmer/Pfam-A.hmm'
    shell:
        '''
        wget -O - {params.url} | gunzip -c - > {output}
        module load {hmmer_version}
        hmmpress {output}
        '''

rule run_hmmscan:
    input: 'ref/hmmer/Pfam-A.hmm', 'results/best_orfs.transdecoder.pep',
    output:tab='results/hmmer/seq_hits.tsv',
        dom='results/hmmer/domain_hits.tsv',
        pfm='results/hmmer/pfam_hits.tsv'
    shell:
        '''
        module load {hmmer_version}
        hmmscan --cpu 24 --tblout {output.tab} --domtblout {output.dom} --pfamtblout {output.pfm} {input}
        '''


rule gtf_to_gff3:
    input:cds='results/transdecoder_results/combined_stringtie_tx.fa.transdecoder.gff3',
        gtf=stringtie_full_gtf
    params:cores='12'
    output: 'results/stringtie_alltissues_cds.gff3'
    shell:
        '''
        module load {R_version}
        Rscript scripts/merge_CDS_gtf.R {input.gtf} {input.cds} {output} {params.cores}
        '''

rule liftOver_gff3:
    input: 'results/stringtie_alltissues_cds.gff3'
    output:'results/stringtie_alltissues_cds_b37.gff3'
    shell:
        '''
        module load {crossmap_version}
        crossmap gff {chain_file} {input} {output}
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
        module load {STAR_version}
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
        module load {STAR_version}
        STAR  --outSAMstrandField intronMotif --outSAMtype BAM Unsorted --alignSJDBoverhangMin 6 \
         --alignIntronMax 299999 --runThreadN 8 --genomeDir {input.index} --sjdbGTFfile {input.gtf} \
         --readFilesIn {input.fastqs} --readFilesCommand gunzip -c --outFileNamePrefix STARbams_realigned/$id/
        '''

rule preprMats_running:
    input: expand('STARbams_realigned/{id}/Aligned.out.bam',id=sample_names)
    output:expand('ref/rmats_locs/{tissue}.rmats.txt',tissue=subtissues)
    shell:
        '''
        module load {R_version}
        Rscript scripts/preprMATSV2.R {config[sampleFile]}
        '''

rule runrMATS:
    input: 'ref/rmats_locs/{tissue}.rmats.txt','ref/STARindex_stringtie',stringtie_full_gtf
    output:expand('rmats_out/{{tissue}}/{event}.MATS.JC.txt', event=rmats_events)
    # might have to change read length to some sort of function
    shell:
        '''
        tissue={wildcards.tissue}
        module load {rmats_version}
        rmats --b1 {input[0]} --b2 ref/rmats_locs/synth.rmats.txt  -t paired --nthread 8 \
         --readLength 130 --gtf {input[2]} --bi {input[1]} --od rmats_out/$tissue
        '''
rule process_rmats_output:
    input: 'rmats_out/{sub_tissue}/{event}.MATS.JC.txt'
    params: event= lambda wildcards: '{}.MATS.JC.txt'.format(wildcards.event)
    output: expand('rmats_clean/{{sub_tissue}}/{type}.{{event}}.MATS.JC.txt',type=['wide','raw','bin','multi'])
    shell:
        '''
        module load {R_version}
        Rscript scripts/process_rmats_output.R {input} {params.event} {sample_file} {wildcards.sub_tissue} {output}
        '''

rule combined_rmats_output:
    input: expand('rmats_clean/{sub_tissue}/bin.{{event}}.MATS.JC.txt', sub_tissue=subtissues)
    params: event= lambda wildcards: '{}.MATS.JC.txt'.format(wildcards.event)
    output:'results/complete_rmats_output/all_tissues.{event}.incLevel.tsv','results/complete_rmats_output/all_tissues.{event}.medCounts.tsv'
    shell:
        '''
        module load {R_version}
        Rscript scripts/combine_rmats_output.R {params.event} {output}
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
        salmon index -t {input} --gencode -i {output} --type quasi --perfectHash -k 31
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
