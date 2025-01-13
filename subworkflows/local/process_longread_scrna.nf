//
// Performs alignment
//

// SUBWORKFLOWS
include { ALIGN_LONGREADS         } from '../../subworkflows/local/align_longreads'
include { QUANTIFY_SCRNA_ISOQUANT } from '../../subworkflows/local/quantify_scrna_isoquant'
include { QUANTIFY_SCRNA_OARFISH  } from '../../subworkflows/local/quantify_scrna_oarfish'
include { UMITOOLS_DEDUP_SPLIT    } from '../../subworkflows/local/umitools_dedup_split'

// MODULES
include { SAMTOOLS_INDEX as SAMTOOLS_INDEX_TAGGED       } from '../../modules/nf-core/samtools/index'
include { SAMTOOLS_FLAGSTAT as SAMTOOLS_FLAGSTAT_TAGGED } from '../../modules/nf-core/samtools/flagstat'

include { TAG_BARCODES } from '../../modules/local/tag_barcodes'


workflow PROCESS_LONGREAD_SCRNA {
    take:
        fasta        // channel: [ val(meta), path(fasta) ]
        fai          // channel: [ val(meta), path(fai) ]
        gtf          // channel: [ val(meta), path(gtf) ]
        fastq        // channel: [ val(meta), path(fastq) ]
        rseqc_bed    // channel: [ val(meta), path(rseqc_bed) ]
        read_bc_info // channel: [ val(meta), path(read_barcode_info) ]
        quant_list   // list: List of quantifiers to use

        skip_save_minimap2_index // bool: Skip saving the minimap2 index
        skip_qc                  // bool: Skip qc steps
        skip_rseqc               // bool: Skip RSeQC
        skip_bam_nanocomp        // bool: Skip Nanocomp
        skip_seurat              // bool: Skip seurat qc steps
        skip_dedup               // bool: Skip umitools deduplication
        split_umitools_bam       // bool: Skip splitting on chromsome for umitools

    main:
        ch_versions = Channel.empty()

        //
        // SUBWORKFLOW: Align long Read Data
        //

        ALIGN_LONGREADS(
            fasta,
            fai,
            gtf,
            fastq,
            rseqc_bed,
            skip_save_minimap2_index,
            skip_qc,
            skip_rseqc,
            skip_bam_nanocomp
        )
        ch_versions = ch_versions.mix(ALIGN_LONGREADS.out.versions)

        //
        // MODULE: Tag Barcodes
        //

        TAG_BARCODES (
            ALIGN_LONGREADS.out.sorted_bam
                .join( ALIGN_LONGREADS.out.sorted_bai, by: 0 )
                .join( read_bc_info, by: 0)
        )
        ch_versions = ch_versions.mix(TAG_BARCODES.out.versions)

        //
        // MODULE: Index Tagged Bam
        //
        SAMTOOLS_INDEX_TAGGED ( TAG_BARCODES.out.tagged_bam )
        ch_versions = ch_versions.mix(SAMTOOLS_INDEX_TAGGED.out.versions)

        //
        // MODULE: Flagstat Tagged Bam
        //
        SAMTOOLS_FLAGSTAT_TAGGED (
            TAG_BARCODES.out.tagged_bam
                .join( SAMTOOLS_INDEX_TAGGED.out.bai, by: [0])
        )
        ch_versions = ch_versions.mix(SAMTOOLS_FLAGSTAT_TAGGED.out.versions)

        //
        // SUBWORKFLOW: UMI Deduplication
        //
        ch_bam = Channel.empty()
        ch_bai = Channel.empty()
        ch_flagstat = Channel.empty()
        ch_dedup_log = Channel.empty()
        ch_idxstats = Channel.empty()

        if (!skip_dedup) {
            UMITOOLS_DEDUP_SPLIT(
                fasta,
                fai,
                TAG_BARCODES.out.tagged_bam,
                SAMTOOLS_INDEX_TAGGED.out.bai,
                split_umitools_bam
            )

            ch_bam = UMITOOLS_DEDUP_SPLIT.out.dedup_bam
            ch_bai = UMITOOLS_DEDUP_SPLIT.out.dedup_bai
            ch_log = UMITOOLS_DEDUP_SPLIT.out.dedup_log
            ch_flagstat = UMITOOLS_DEDUP_SPLIT.out.dedup_flagstat
            ch_idxstats = UMITOOLS_DEDUP_SPLIT.out.dedup_idxstats

            ch_versions = ch_versions.mix(UMITOOLS_DEDUP_SPLIT.out.versions)
        } else {
            ch_bam = TAG_BARCODES.out.tagged_bam
            ch_bai = SAMTOOLS_INDEX_TAGGED.out.bai
            ch_flagstat = SAMTOOLS_FLAGSTAT_TAGGED.out.flagstat
        }

        //
        // SUBWORKFLOW: Quantify Features
        //

        ch_gene_qc_stats = Channel.empty()
        ch_transcript_qc_stats = Channel.empty()

        if (quant_list.contains("oarfish")) {
            QUANTIFY_SCRNA_OARFISH (
                ch_bam,
                ch_bai,
                ch_flagstat,
                fasta,
                skip_qc,
                skip_seurat
            )
            ch_versions = ch_versions.mix(QUANTIFY_SCRNA_OARFISH.out.versions)
            ch_transcript_qc_stats = QUANTIFY_SCRNA_OARFISH.out.transcript_qc_stats
        }

        if (quant_list.contains("isoquant")) {
            QUANTIFY_SCRNA_ISOQUANT (
                ch_bam,
                ch_bai,
                ch_flagstat,
                fasta,
                fai,
                gtf,
                skip_qc,
                skip_seurat
            )

            ch_versions = ch_versions.mix(QUANTIFY_SCRNA_ISOQUANT.out.versions)
            ch_gene_qc_stats = QUANTIFY_SCRNA_ISOQUANT.out.gene_qc_stats
            ch_transcript_qc_stats = QUANTIFY_SCRNA_ISOQUANT.out.transcript_qc_stats
        }

    emit:
        // Versions
        versions                 = ch_versions

        // Minimap results + qc's
        minimap_bam              = ALIGN_LONGREADS.out.sorted_bam
        minimap_bai              = ALIGN_LONGREADS.out.sorted_bai
        minimap_stats            = ALIGN_LONGREADS.out.stats
        minimap_flagstat         = ALIGN_LONGREADS.out.flagstat
        minimap_idxstats         = ALIGN_LONGREADS.out.idxstats
        minimap_rseqc_read_dist  = ALIGN_LONGREADS.out.rseqc_read_dist
        minimap_nanocomp_bam_txt = ALIGN_LONGREADS.out.nanocomp_bam_txt

        // Barcode tagging results + qc's
        bc_tagged_bam            = TAG_BARCODES.out.tagged_bam
        bc_tagged_bai            = SAMTOOLS_INDEX_TAGGED.out.bai
        bc_tagged_flagstat       = SAMTOOLS_FLAGSTAT_TAGGED.out.flagstat

        // Deduplication results
        dedup_bam                = ch_bam
        dedup_bai                = ch_bai
        dedup_log                = ch_dedup_log
        dedup_flagstat           = ch_flagstat
        dedup_idxstats           = ch_idxstats

        // Seurat QC Stats
        gene_qc_stats            = ch_gene_qc_stats
        transcript_qc_stats      = ch_transcript_qc_stats
}
