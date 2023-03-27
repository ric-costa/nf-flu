#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

//=============================================================================
// NCBI Influenza DB reference data
//=============================================================================

ch_influenza_db_fasta = file(params.ncbi_influenza_fasta)
ch_influenza_metadata = file(params.ncbi_influenza_metadata)

//=============================================================================
// MODULES
//=============================================================================

include { IRMA } from '../modules/local/irma'
include { CHECK_SAMPLE_SHEET } from '../modules/local/check_sample_sheet'
include { SUBTYPING_REPORT } from '../modules/local/subtyping_report'
include { GUNZIP_NCBI_FLU_FASTA } from '../modules/local/misc'
include { BLAST_MAKEBLASTDB } from '../modules/local/blast_makeblastdb'
include { BLAST_BLASTN } from '../modules/nf-core/modules/blast/blastn/main'
include { CAT_FASTQ } from '../modules/nf-core/modules/cat/fastq/main'
include { NEXTCLADE_RUN } from '../modules/nf-core/modules/nextclade/run/main'

//=============================================================================
// Workflow Params Setup
//=============================================================================

def irma_module = 'FLU-utr'
if (params.irma_module) {
    irma_module = params.irma_module
}

//=============================================================================
// WORKFLOW
//=============================================================================

workflow ILLUMINA {

  GUNZIP_NCBI_FLU_FASTA(ch_influenza_db_fasta)
  BLAST_MAKEBLASTDB(GUNZIP_NCBI_FLU_FASTA.out.fna)

  CHECK_SAMPLE_SHEET(Channel.fromPath( params.input, checkIfExists: true))
    .splitCsv(header: ['sample', 'fastq1', 'fastq2', 'single_end'], sep: ',', skip: 1)
    .map {
      def meta = [:]
      meta.id = it.sample
      meta.single_end = it.single_end.toBoolean()
      def reads = []
      def fastq1 = file(it.fastq1)
      def fastq2
      if (!fastq1.exists()) {
        exit 1, "ERROR: Please check input samplesheet. FASTQ file 1 '${fastq1}' does not exist!"
      }
      if (meta.single_end) {
        reads = [fastq1]
      } else {
        fastq2 = file(it.fastq2)
        if (!fastq2.exists()) {
          exit 1, "ERROR: Please check input samplesheet. FASTQ file 2 '${fastq2}' does not exist!"
        }
        reads = [fastq1, fastq2]
      }
      [ meta, reads ]
    } 
    .groupTuple(by: [0]) \
    .branch { meta, reads ->
      single: reads.size() == 1
        return [ meta, reads.flatten() ]
      multiple: reads.size() > 1
        return [ meta, reads.flatten() ]
    }
    .set { ch_input }

  // Credit to nf-core/viralrecon. Source: https://github.com/nf-core/viralrecon/blob/a85d5969f9025409e3618d6c280ef15ce417df65/workflows/illumina.nf#L221
  // Concatenate FastQ files from same sample if required
  CAT_FASTQ(ch_input.multiple)
    .mix(ch_input.single)
    .set { ch_cat_reads }

  IRMA(ch_cat_reads, irma_module)

  BLAST_BLASTN(IRMA.out.consensus, BLAST_MAKEBLASTDB.out.db)

  ch_blast = BLAST_BLASTN.out.txt.collect({ it[1] })
  SUBTYPING_REPORT(ch_influenza_metadata, ch_blast)


  outputPath = "$params.outdir"
  subtypesPath = "$outputPath/subtypes.csv"
  referencePath = "az://assets/flu" //#FIXME
  irmaDir = "$outputPath/irma"

  params.nextclade_dataset = null   
  SUBTYPING_REPORT.out.report
  .splitCsv(header: ['sample', 'subtype'], skip: 1)
  .filter (row -> row.subtype.length() >  1) //filter out samples with no determined subtypes
  .map { row ->
      def sample = row.sample
      def subtype = row.subtype
      println ("Staging sample ${sample} (${subtype} subtype) for clade analysis.")
      if ( subtype.length() <  2)
          println ("   -Skipping sample ${sample}. No subtype determined") //FIXME
      if ( subtype.startsWith('H1') ) {
          dataset = "${referencePath}/flu_h1n1pdm_ha"
      } else {
          if ( subtype.startsWith('H3') ) {
              dataset =  "${referencePath}/flu_h3n2_ha"
          } else { 
              println ("Sample HA subtype other than H1 or H3 found for sample ${sample}") 
          }   
      }
      fasta = "${irmaDir}/${sample}.irma.consensus.fasta"
      [ sample, fasta, dataset ]
  }
  .set { ch_samples }
  ch_samples.view()


    NEXTCLADE_RUN (
        ch_samples.map {it -> [it[0], it[1]]},
        ch_samples.map {it -> [it[2]]}
    )
  

}
