library(tidyverse)
#baseline model file
baseline_model <- read.table("reference_files/ms_baseline_oe5.txt")

#key function for wrangling
wrangle_sumstats <- function(table,n_cases,n_controls) {
  print("calculating key paramters")
  prevalence = n_cases/(n_cases+n_controls)

  table$MAF_case = table$ac_case/(2*n_cases)
  table$MAF = (table$ac_case + table$ac_ctrl)/(2*(n_cases + n_controls))

  #calculate betas
  table$beta = (2 * (table$MAF_case - table$MAF) * prevalence)/sqrt(2 * table$MAF * (1 - table$MAF) * prevalence * (1 - prevalence))

  #calculate variances
  table$pq_j = 2*table$MAF * (1 - table$MAF)

  #convert betas from per-sd (i.e. sqrt(variance explained)) to per-allele (i.e. in units of phenotype) betas.
  #per-allele are the usual betas reported by an exome wide association study.
  table$beta_perallele = table$beta/sqrt(table$pq_j)

  #aggregate into gene-level table.
  sumstats = data.frame(gene = unique(table$gene_id))
  sumstats$variant_variances = lapply(sumstats$gene,
                                      function(x) table$pq_j[table$gene_id == x])
  sumstats$betas = lapply(sumstats$gene,
                                      function(x) table$beta_perallele[table$gene_id == x])


  names(sumstats) <- c("gene", "variant_variances","betas")

  #add chromosome and position information
  #position doesn't need to be super precise, as it is only used to order genes for jackknife
  sumstats$gene_position <- parse_number(sapply(strsplit(table$locus[match(sumstats$gene,table$gene_id)], split = ":"), function(x) x[[2]]))
  sumstats$chromosome = parse_number(sapply(strsplit(table$locus[match(sumstats$gene,table$gene_id)], split = ":"), function(x) x[[1]]))

  #N = harmonic mean of cases and controls.
  sumstats$N = 2*(((1/n_cases) + (1/n_controls))^-1)

  return(sumstats)
}

#Read in data. This file has been subset to rows where "in_analysis" == true, to mimic the Bipex main sample
# data was downloaded from https://atgu-exome-browser-data.s3.amazonaws.com/BipEx/BipEx_variant_results.tsv.bgz and then run 'gunzip -c BipEx_variant_results.tsv.bgz > BipEx_variant_results.tsv'
bp_variantlevel_bipex <- bigreadr::fread2("./example/BipEx_variant_results.tsv")

# subset to following variants to represent for bipolar disorder (Q1: any further filtering needed?)
bp_variantlevel_bipex <- bp_variantlevel_bipex %>%
  filter(group == "Bipolar Disorder",
         in_analysis == "TRUE",
         str_detect(locus, "^chr\\d"),
         !is.na(gene_id))

#subset to PTV
bp_variantlevel_bipex_ptv <- bp_variantlevel_bipex %>%
  filter(consequence == "ptv") %>%
  select(gene_id, consequence, ac_case, ac_ctrl, locus)

#wrangle sumstats
bp_ptv_sumstats <- wrangle_sumstats(bp_variantlevel_bipex_ptv,14210,14422)

#we have found that in these smaller sample analyses, there are some genes with
#large burden scores that are clearly outliers
#we remove genes with burden scores more than 8 sd from the mean as a conservative filter.
burden_scores = sapply(bp_ptv_sumstats$variant_variances, function(x) sum(x))
bp_ptv_sumstats_filtered = bp_ptv_sumstats[scale(burden_scores) < 8,]

#run BHR
bp_ptv_filtered_bhr <- bhr::BHR(bp_ptv_sumstats_filtered, annotations = list(baseline_model),num_blocks = 100,genomewide_correction = FALSE, num_null_conditions = 5,mode = "univariate")

#convert observed scale h2 to liability

#calculate sample prevalence
bp_sample_prevalence = 14210/(14210 + 14422)

#this population prevalence estimate is from Ferrari et al, 2016 Bipolar Disorders
population_prevalence_bp = 0.007

obs2lia_factor <- function(K, P){
  X <- qnorm(K,lower.tail=FALSE)
  z <- (1/sqrt(2*pi))*(exp(-(X**2)/2))
  factor <- (K*(1-K)*K*(1-K))/(P*(1-P)*(z**2))
  return(factor)
}

bp_scalingfactor = obs2lia_factor(population_prevalence_bp,bp_sample_prevalence)

#print final liability_scale heritability estimate
#i realize this number is very slightly off the preprint estimate (e.g. by 0.0015), this is likely due to
#some small software changes we made late in the game, and will be updated for the pub.
print(bp_ptv_filtered_bhr$mixed_model$heritabilities[1,5]*bp_scalingfactor)   # Q2: I got 0.0184, which is actually a little bit larger than corrected preprint estimate (i.e. 0.032/2 = 0.016 (figure 6A)), what makes the difference? would it be we used different subset of LoF variants here?
