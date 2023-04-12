// Import generic module functions
include { getSoftwareName } from './functions'


process IRMA {
  tag "$meta.id"
  label 'process_high'

  conda (params.enable_conda ? "bioconda::irma=1.0.3" : null)
  if (workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container) {
    container 'https://depot.galaxyproject.org/singularity/irma:1.0.3--pl5321hdfd78af_0'
  } else {
    container 'quay.io/biocontainers/irma:1.0.3--pl5321hdfd78af_0'
  }

  input:
  tuple val(meta), path(reads)
  val (irma_module)
  
  output:
  tuple val(meta), path("${meta.id}/"), emit: irma
  tuple val(meta), path("${meta.id}.irma.consensus.fasta"), optional: true, emit: consensus
  path "*.irma.log", emit: log
  path "versions.yml" , emit: versions

  script:
  def software = getSoftwareName(task.process)
  irma_config = "DEL_TYPE=\"NNN\"\nALIGN_PROG=\"BLAT\""
  irma_log    = "${meta.id}.irma.log"
  """
  touch irma_config.sh
  echo 'SINGLE_LOCAL_PROC=${task.cpus}' >> irma_config.sh
  echo 'DOUBLE_LOCAL_PROC=${(task.cpus / 2).toInteger()}' >> irma_config.sh
  if [ ${params.keep_ref_deletions} ]; then
    echo 'DEL_TYPE="NNN"' >> irma_config.sh
    echo 'ALIGN_PROG="BLAT"' >> irma_config.sh
  fi

  IRMA $irma_module $reads $meta.id
  
  if [ -d "${meta.id}/amended_consensus/" ]; then
    cat ${meta.id}/amended_consensus/*.fa > ${meta.id}.irma.consensus.fasta
  fi
  ln -s .command.log $irma_log
  cat <<-END_VERSIONS > versions.yml
  "${task.process}":
     IRMA: \$(IRMA | head -n1 | sed -E 's/^Iter.*IRMA\\), v(\\S+) .*/\\1/')
  END_VERSIONS
  """
}
