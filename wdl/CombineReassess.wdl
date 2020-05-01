version 1.0

import "https://raw.githubusercontent.com/broadinstitute/gatk-sv-clinical/v0.7.1/wdl/Structs.wdl"

workflow CombineReassess {
  input {
      File samplelist
      File regeno_file
      File cohort_cluster
      Array[File] vcfs 
      String sv_pipeline_base_docker
      String sv_pipeline_docker
      RuntimeAttr? runtime_attr_vcf2bed
  }
  scatter(vcf in vcfs){
      call Vcf2Bed{
        input:
            vcf=vcf,
            regeno_file=regeno_file,
            sv_pipeline_docker=sv_pipeline_docker,
            runtime_attr_override=runtime_attr_vcf2bed}
  }
  call MergeList{
    input:
        nonempty_txt=Vcf2Bed.nonempty,
        regeno_file=regeno_file,
        cohort_cluster=cohort_cluster,
        samplelist=samplelist,
        sv_pipeline_base_docker=sv_pipeline_base_docker}
  output {
    File regeno_variants=MergeList.regeno_var
  }
}

task Vcf2Bed{
  input {
    File vcf
    File regeno_file
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75,
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    command<<<
        set -euo pipefail
        svtk vcf2bed ~{vcf} ~{vcf}.bed 
        awk '{if($6!="")print $0}' ~{vcf}.bed >~{vcf}.nonempty.bed  
        cut -f 4 ~{regeno_file} >regeno_variants.txt
        fgrep -f regeno_variants.txt ~{vcf}.nonempty.bed> nonempty.txt        
    >>>
    output{
        File nonempty="nonempty.txt"
    }
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task MergeList{
    input {
        File samplelist
        File regeno_file
        Array[File] nonempty_txt
        File cohort_cluster
        String sv_pipeline_base_docker
        RuntimeAttr? runtime_attr_override
  }
  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75,
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])
    command<<<
        set -e
        cut -f 4 ~{regeno_file} >regeno_variants.txt
        fgrep -f regeno_variants.txt ~{cohort_cluster} > cohort.regeno_var.combined.bed
        cat ~{sep=' ' nonempty_txt}|sort -k1,1V -k2,2n -k3,3n |bgzip -c > nonempty.bed.gz
        tabix nonempty.bed.gz
        # For each variant in regeno_file, take variants across all batches
        while read chr start end var type;do
            samplelist=$(tabix nonempty.bed.gz $chr:$start-$end |awk -v var="$var" '{if($4==var)print $6}' |tr "\n" ",")
            printf "$chr\t$start\t$end\t$var\t$samplelist\n" 
        done<~{regeno_file} >regeno_variant_sample.txt
        # Use cohort cluster file, add samples that are clustered with the variant in question across whole cohort
        while read chr start end var sample;do
            expected_samples=$(fgrep $var: cohort.regeno_var.combined.bed |cut -f8)
            printf "$var\t$sample\t$expected_samples\n"
        done<regeno_variant_sample.txt > reassesss_by_var.txt
        python3 <<CODE
        import numpy as np
        dct={}
        def count(ln):
            dat=ln.split("\t")
            slist=dat[1].split(',')
            for s in slist:
                try:
                    dct[s]+=1
                except:
                    pass
        with open("~{samplelist}",'r') as f:
            for line in f:
                dct[line.rstrip()]=0
        # Reject all outliers
        with open("reassesss_by_var.txt",'r') as f: #
            for line in f:
                count(line)
        counts=np.array([int(dct[x]) for x in dct.keys()])
        def reject_outliers(data, m=3):
            return data[abs(data - np.mean(data)) > m * np.std(data)]
        outliers=reject_outliers(counts)
        outlier_samples=set([x for x in dct.keys() if dct[x] in outliers])
        with open("reassess_nonzero_overlap.txt",'w') as g, open("reassesss_by_var.txt",'r') as f:
            for line in f:
                dat=line.rstrip().split('\t')
                regeno=dat[1][0:-1].split(',') # extra comma in the end
                expected=dat[2][0:-1].split(',')
                regeno=set([item for item in regeno if item not in outlier_samples])
                expected=set([item for item in expected if item not in outlier_samples])
                if not regeno.isdisjoint(expected):
                    regeno_in_expected=[x for x in regeno if x in expected]
                    overlap_over_regeno=str(len(regeno_in_expected)/len(regeno))
                    overlap_over_expected=str(len(regeno_in_expected)/len(expected))
                    g.write(dat[0]+"\t"+",".join(regeno)+'\t'+",".join(expected)+'\t'+overlap_over_regeno+'\t'+overlap_over_expected+"\n")
        CODE
        awk '{if($4>0.7 && $5>0.7)print $1}' reassess_nonzero_overlap.txt > regeno_var_filtered.txt
        fgrep -w -f regeno_var_filtered.txt ~{regeno_file}> regeno.filtered.bed
    >>>
    output{
        File reassess_nonzero="reassess_nonzero_overlap.txt"
        File regeno_filtered="regeno.filtered.bed"
        File regeno_var="regeno_var_filtered.txt"
        File nonempty_bed="nonempty.bed.gz"
    }
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_base_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}
