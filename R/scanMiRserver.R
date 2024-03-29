#' scanMiRserver
#'
#' Server function for the scanMiR shiny app. Most users are expected to use
#' \code{\link{scanMiRApp}} instead.
#'
#' @param annotations A named list of \code{\link{ScanMiRAnno}} object.
#' @param modlists A named list of `KdModelList` objects. If omitted, will
#' fetch it from the annotation objects.
#' @param maxCacheSize Maximum cache size in bytes.
#' @param BP BPPARAM for multithreading
#'
#' @return A shiny server function
#' @importFrom digest digest
#' @importFrom BiocParallel SerialParam
#' @importFrom plotly renderPlotly ggplotly event_data event_register
#' @importFrom ensembldb genes transcripts exonsBy threeUTRsByTranscript
#' @importFrom DT datatable renderDT DTOutput
#' @importFrom htmlwidgets JS
#' @importFrom digest digest
#' @importFrom shinycssloaders withSpinner
#' @importFrom ggplot2 ggplot aes_string geom_hline geom_point expand_limits
#' xlab geom_vline geom_rect theme_minimal theme element_line scale_x_continuous
#' scale_y_continuous
#' @importFrom AnnotationDbi select
#' @importFrom Biostrings DNAStringSet RNAString DNAString
#' @importFrom waiter waiter_hide waiter_show
#' @importFrom rintrojs hintjs introjs readCallback
#' @importFrom utils capture.output object.size write.csv packageVersion
#' @importFrom S4Vectors mcols mcols<-
#' @import shiny shinydashboard scanMiR GenomicRanges IRanges
#' @export
#' @examples
#' # we'd normally fetch a real annotation:
#' # anno <- ScanMiRAnno("Rnor_6")
#' # here we'll use a fake one:
#' anno <- ScanMiRAnno("fake")
#' srv <- scanMiRserver(list(fake=anno))
scanMiRserver <- function( annotations=list(), modlists=NULL,
                           maxCacheSize=10*10^6, BP=SerialParam() ){
  stopifnot(length(annotations)>0)
  stopifnot(all(vapply(annotations, class2="ScanMiRAnno",
                       FUN.VALUE=logical(1), FUN=is)))
  if(is.null(modlists))
    modlists <- lapply(annotations, FUN=function(x) x$models)
  stopifnot(all(vapply(modlists, class2="KdModelList",
                       FUN.VALUE=logical(1), FUN=is)))
  stopifnot(all(names(modlists) %in% names(annotations)))

  dtwrapper <- function(d, pageLength=25, rownames=TRUE, ...){
    datatable( d, filter="top", class="compact",
               extensions=c("Buttons","ColReorder"),
               options=list(
                 pageLength=pageLength, dom = "fltBip", colReorder=TRUE,
                 buttons=c('copy', 'csv', 'excel', 'csvHtml5', 'colvis')
               ), rownames=rownames, ... )
  }

  checkModIdentity <- function(m1,m2){
    identical(lapply(m1,FUN=function(x) x$mer8),
              lapply(m2,FUN=function(x) x$mer8))
  }

  getTxs <- function(db, gene=NULL){
    if(is.null(gene)) return(NULL)
    if(is(db,"EnsDb")){
      if(!is.null(gene)) filt <- ~gene_id==gene
      tx <- transcripts(db, columns=c("tx_id","tx_biotype"),
                        filter=~gene_id==gene, return.type="data.frame")
    }else{
      tx <- suppressMessages(try(select(db, keys=gene, keytype="GENEID",
                                    columns=c("TXNAME","TXTYPE")), silent=TRUE))
      if(is(tx,"try-error")) return(NULL)
      colnames(tx) <- c("gene","tx_id","tx_biotype")
    }
    if(nrow(tx)==0) return(NULL)
    setNames(tx$tx_id, paste0(tx$tx_id, " (",tx$tx_biotype, ")"))
  }

  getGeneFromTx <- function(db, tx){
    if(is(db,"EnsDb")){
      tx <- transcripts(db, columns=c("tx_id","gene_id"),
                        filter=~tx_id==tx, return.type="data.frame")
      return(as.character(tx$gene_id[1]))
    }
    tx <- suppressMessages(try(select(db, keys=tx, keytype="TXNAME",
                                      columns=c("TXID","GENEID")), silent=TRUE))
    if(is(tx,"try-error")) return(NULL)
    as.character(tx$GENEID[1])
  }

  function(input, output, session){

    #############################
    ## intro

    startIntro <- function(session){
      introjs(session, options=list(steps=.getAppIntro(), "nextLabel"="Next",
                                    "prevLabel"="Previous"),
              events=list(onbeforechange=readCallback("switchTabs")))
    }
    
    observeEvent(input$helpBtn, startIntro(session))
    observeEvent(input$helpLink, startIntro(session))

    ##############################
    ## initialize inputs

    output$menuCollection <- renderUI({
      menuItem(tags$span("miRNA Collection:", 
                         HTML("<br/>&nbsp;&nbsp;&nbsp;&nbsp;"), input$mirlist),
               tabName="tab_collection")
    })
    output$menuMirnas <- renderUI({
      if( (nsel <- length(selmods()))== 0){
        lab <- "miRNAs (none selected)"
      }else{
        lab <- paste0("miRNAs (", nsel, ")")
      }
      menuSubItem(lab, "tab_mirnas")
    })
    
    updateSelectizeInput(session, "mirlist", choices=names(modlists))
    updateSelectizeInput(session, "annotation", choices=names(annotations))

    observe({
      # when the choice of collection changes, update the annotation to
      # use the same genome
      if(!is.null(input$mirlist) && input$mirlist!="")
        updateSelectizeInput(session, "annotation", selected=input$mirlist)
    })


    ##############################
    ## select collection

    allmods <- reactive({ # all models from collection
      if(is.null(input$mirlist)) return(NULL)
      modlists[[input$mirlist]]
    })

    # prints a summary of the model collection
    output$collection_summary <- renderPrint({
      if(is.null(input$mirlist) || is.null(annotations[[input$mirlist]]))
        return(NULL)
      summary(allmods())
      ad <- annotations[[input$mirlist]]$addDBs
      if(!is.null(ad) && length(ad)>0)
        cat("\nAdditional DB(s):", paste(names(ad), collapse=", "))
    })
    output$selected_collection <- renderValueBox({
      if(is.null(input$mirlist) || is.null(annotations[[input$mirlist]]))
        return(valueBox("N/A", subtitle = "Nothing loaded", color="light-blue"))
      valueBox(input$mirlist, color = "light-blue",
        tags$div(lapply(capture.output(print(annotations[[input$mirlist]])),
               FUN=function(x) tags$p(x)))
      )
    })


    observe({ ## when the selected collection changes,
              ## update the miRNA selection inputs
      updateSelectizeInput(session, "mirnas", choices=names(allmods()),
                           server=TRUE)
      updateSelectizeInput(session, "mirna", choices=names(allmods()),
                           server=TRUE)
    })

    ##############################
    ## scan specific sequence

    ## transcript selection

    sel_ensdb <- reactive({ # the ensembldb for the selected genome
      if(is.null(input$annotation) || input$annotation=="" ||
         !(input$annotation %in% names(annotations))) return(NULL)
      annotations[[input$annotation]]$ensdb
    })

    allgenes <- reactive({ # all genes in the selected genome
      if(is.null(sel_ensdb())) return(NULL)
      if(is(sel_ensdb(), "EnsDb")){
        sl <- gsub("^chr","",seqlevels(annotations[[input$annotation]]$genome))
        g <- genes(sel_ensdb(), columns="gene_name", return.type="data.frame",
                   filter=SeqNameFilter(sl))
        gs <- setNames(g[,2], paste(g[,1], g[,2]))
      }else{
        g <- genes(sel_ensdb())
        names(gs) <- gs <- g$gene_id
        if(!is.null(g$gene_name)){
          names(gs) <- paste(g$gene_name, gs)
        }
      }
      gs
    })

    selgene <- reactive({ # selected gene id
      if(is.null(input$gene) || input$gene=="") return(NULL)
      input$gene
    })

    output$gene_link <- renderUI({
      if(is.null(selgene()) || selgene()=="") return(NULL)
      base <- annotations[[input$annotation]]$ensembl_gene_baselink
      if(is.null(base)) return(NULL)
      tags$a(href=paste0(base, selgene()), icon("external-link"),
             "view on ensembl", target="_blank")
    })

    alltxs <- reactive({ # all tx from selected gene
      if(is.null(selgene()) || selgene()=="") return(NULL)
      getTxs(sel_ensdb(), selgene())
    })

    seltx <- reactive({ # the selected transcript
      if(is.null(input$transcript) || input$transcript=="" ||
         is.na(input$transcript))
        return(NULL)
      changeFlag()
      input$transcript
    })

    # when the ensembldb is updated, update the gene input
    observe(updateSelectizeInput(session, "gene", choices=allgenes(),
                                 server=TRUE))
    # when the gene selection is updated, update the transcript input
    observe({
      prev_seltx <- input$transcript
      if(!(prev_seltx %in% alltxs())) prev_seltx <- NULL
      txs <- alltxs()
      if(is.null(txs)) txs <- c()
      updateSelectizeInput(session, "transcript", choices=alltxs(), selected=prev_seltx)
    })

    # takes a genome package name as input, and returns the genome
    getGenome <- function(x){
      if(is.character(x)){
        x <- library(x, character.only=TRUE)
        x <- get(x)
      }else if(is(x,"ScanMiRAnno")){
        x <- x$genome
      }
      seqlevels(x) <- gsub("^chr","",seqlevels(x))
      x
    }

    seqs <- reactive({ # returns the selected sequence(s)
      if((is.null(selgene()) || selgene()=="") &&
         (is.null(seltx()) || seltx()=="")) return(DNAStringSet())
      gid <- selgene()
      if(is.null(txid <- seltx())) txid <- getTxs(sel_ensdb(), gid)
      getTranscriptSequence( txid, annotations[[input$annotation]],
                             extract=switch(input$seqFeature,
         "CDS+UTR"="withORF", "whole transcript"="exons", "UTRonly"))
    })

    output$tx_overview <- renderTable({ # overview of the selected transcript
      if(is.null(seqs()) || length(seqs())==0)
        return(data.frame(sequence="Empty sequence!"))
      w <- width(seqs())
      ss <- as.character(subseq(seqs(), 1, end=ifelse(w<40,w,40)))
      ss[w>40] <- paste0(ss[w>40],"...")
      data.frame(transcript=names(seqs()), length=w, sequence=ss)
    })

    ## end transcript selection

    ## custom sequence

    customTarget <- reactive({
      if(is.null(input$customseq) || input$customseq=="") return(NULL)
      isRNA <- grepl("U", input$customseq, fixed=TRUE)
      seq <- gsub("[^ACGTUN]","", toupper(input$customseq))
      if(input$circular) seq <- paste0(seq,substr(seq,1,min(nchar(seq),11)))
      if(isRNA) seq <- RNAString(seq)
      DNAString(seq)
    })

    output$custom_info <- renderPrint({ # overview of the custom sequence
      if(is.null(input$customseq)) return("")
      out <- capture.output(customTarget())
      if(input$circular)
        out <- c("Circularized sequence: the first 11nt are pasted to ",
                 "the end of the sequence.\n", out)
      cat(out)
    })

    target <- reactive({ # target subject sequence
      if(input$subjet_type=="custom"){
        return(as.character(DNAStringSet(customTarget())))
      }
      if(is.null(seqs()) || length(seqs())>1) return(NULL)
      changeFlag()
      as.character(seqs())
    })

    observeEvent(input$rndseq, { # generate random sequence
      updateTextAreaInput(session, "customseq",
                          value=as.character(getRandomSeq()))
    })

    ## Select miRNAs for scanning

    observeEvent(input$mirnas_confident, {
      if(is.null(allmods())) return(NULL)
      cons <- conservation(allmods())
      if(all(is.na(cons))) return(NULL)
      updateSelectizeInput(session, "mirnas",
                           selected=names(cons)[as.numeric(cons)>1])
    })
    observeEvent(input$mirnas_mammals, {
      if(is.null(allmods())) return(NULL)
      cons <- conservation(allmods())
      if(all(is.na(cons))) return(NULL)
      updateSelectizeInput(session, "mirnas",
                           selected=names(cons)[as.numeric(cons)>2])
    })
    observeEvent(input$mirnas_vert, {
      if(is.null(allmods())) return(NULL)
      cons <- conservation(allmods())
      if(all(is.na(cons))) return(NULL)
      updateSelectizeInput(session, "mirnas",
                           selected=names(cons)[as.numeric(cons)>3])
    })
    observeEvent(input$mirnas_clear, {
      updateSelectizeInput(session, "mirnas", selected="")
    })
    
    observe({
      if(!is.null(input$mirnas) && length(input$mirnas)>0)
        updateCheckboxInput(session, "mirnas_all", value=FALSE)
    })
    observe({
      if(input$mirnas_all)
        updateSelectizeInput(session, "mirnas", selected="")
    })

    selmods <- reactive({ # models selected for scanning
      if(is.null(allmods())) return(NULL)
      if(input$mirnas_all) return(allmods())
      if(is.null(input$mirnas)) return(NULL)
      allmods()[input$mirnas]
    })

    ## Begin scan and results caching

    output$scanBtn <- renderUI({
      if(is.null(target()) || !isTRUE(nchar(target())>0) ||
         is.null(selmods()) || length(selmods())==0)
        return(actionButton("noscan", "Cannot launch scan - check input",
                            icon("exclamation-triangle"), disabled=TRUE))
      actionButton("scan", "Scan!", icon = icon("search"))
   })

    # actual and past scanning results are stored in this object
    cached.hits <- reactiveValues()

    changeFlag <- reactiveVal(0)

    cached.checksums <- reactive({
      ch <- reactiveValuesToList(cached.hits)
      ch <- ch[!vapply(ch, FUN.VALUE=logical(1), FUN=is.null)]
      ch <- lapply(ch, FUN=function(x){
        x[c("target","size","time","last","nsel","sel")]
      })
    })
    current.cs <- reactiveVal()

    hits <- reactive({ # the results currently loaded are stored in this object
      if(is.null(current.cs())) return(NULL)
      if(current.cs() %in% names(cached.checksums()))
        return(cached.hits[[current.cs()]])
      NULL
    })

    checksum <- reactive({ # generate a unique hash for the given input
      changeFlag()
      paste( digest::digest(selmods()),
             digest::digest(list(target=target(), shadow=input$shadow,
                                 keepMatchSeq=input$keepMatchSeq,
                                 minDist=input$minDist, maxLogKd=input$maxLogKd,
                                 scanNonCanonical=input$scanNonCanonical))
      )
    })

    cache.size <- reactive({
      ch <- cached.checksums()
      if(is.null(ch) || length(ch)==0) return(0)
      sum(vapply(ch, FUN.VALUE=numeric(1), FUN=function(x) as.numeric(x$size)))
    })

    cleanCache <- function(){
      # remove last-used results when over the cache size limit
      cs <- isolate(cached.checksums())
      if(length(cs)<3 || as.numeric(cache.size())<maxCacheSize) return(NULL)
      cs <- cs[order(unlist(lapply(cs,FUN=function(x) x$last)),decreasing=TRUE)]
      sizes <- vapply(ch, FUN.VALUE=numeric(1), FUN=function(x)
                                                            as.numeric(x$size))
      while(length(cs)>2 & sum(sizes)>maxCacheSize){
        cached.hits[[rev(names(cs))[1]]] <- NULL
        cs <- cs[-length(cs)]
        sizes <- sizes[-length(sizes)]
      }
    }

    checkPreComputedScan <- function(txid, utr_only=FALSE){
      if(is.null(preScan <- annotations[[input$annotation]]$scan)) return(NULL)
      if(is.null(origMods <- annotations[[input$annotation]]$models) ||
         !all(names(selmods()) %in% names(origMods)) ||
         !checkModIdentity(selmods(), origMods[names(selmods())])){
        warning("The models are not the same as those present in the ",
                "annotation; ignoring pre-compiled scans.")
        return(NULL)
      }
      if(is(preScan, "GRanges")){
        if(!(txid %in% seqlevels(preScan))){
          warning("Transcript not found in the pre-compiled scan!")
          return(NULL)
        }
        h <- preScan[seqnames(preScan)==txid &
                       preScan$miRNA %in% names(selmods())]
      }else{
        if(!(txid %in% names(preScan))){
          warning("Transcript not found in the pre-compiled scan!")
          return(NULL)
        }
        h <- preScan[[txid]]
        h <- h[h$miRNA %in% names(selmods())]
      }
      if(utr_only && !is.null(h$ORF)){
        h <- h[!h$ORF]
        h$ORF <- NULL
        if(!is.null(metadata(h)$tx_info)){
          s <- metadata(h)$tx_info[as.character(seqnames(h)), "ORF.length"]
          h <- IRanges::shift(h, -1L * as.integer(s))
        }
      }
      if(length(h)==0) return(h)
      if(!input$scanNonCanonical)
        h <- h[grep("canonical|bulged",h$type,invert=TRUE)]
      h <- h[h$log_kd < input$maxLogKd]
      h[order(h$log_kd)]
    }

    observeEvent(input$scan, { # actual scanning
      if(is.null(selmods()) || is.null(target()) || nchar(target())==0)
        return(NULL)
      cs <- checksum()
      cached.hits[[cs]] <- do.scan()
      current.cs(cs)
    })

    do.scan <- reactive({
      if(is.null(selmods()) || is.null(target()) || length(target())==0 ||
        nchar(target())==0){
        waiter_hide()
        return(NULL)
      }
      tmp <- changeFlag()
      cs <- checksum()
      # first check if we already have these results cached:
      if(cs %in% names(cached.checksums())) return(cached.hits[[cs]])
      waiter_show(color = "#333E4850")
      # then check if the results are pre-computed
      if(input$subjet_type!="custom" && input$seqFeature!="whole transcript" &&
         !is.null(h <- checkPreComputedScan(seltx(), input$seqFeature=="3' UTR only"))){
        res <- list(hits=h)
      }else{
        res <- list()
        msg <- paste0("Scanning sequence for ",length(selmods())," miRNAs")
        message(msg)
        detail <- NULL
        if(length(selmods())>4) detail <- "This might take a while..."
        if(input$circular)
          detail <- "'Ribosomal Shadow' is ignored when scanning circRNAs"
        scantarget <- target()
        scanmods <- selmods()
        keepmatchseq <- input$keepmatchseq
        shadow <- ifelse(input$circular,0,input$shadow)
        onlyCanonical <- !input$scanNonCanonical
        minDist <- input$minDist
        maxLogKd <- input$maxLogKd
        withProgress(message=msg, detail=detail, value=1, max=3, {
          res$hits = findSeedMatches(
              scantarget, scanmods, keepMatchSeq=keepmatchseq,
              minDist=minDist, maxLogKd=maxLogKd, shadow=shadow,
              onlyCanonical=onlyCanonical, p3.extra=TRUE, BP=BP )
        })
      }
      if(length(res$hits)>0){
        res$hits$log_kd <- (res$hits$log_kd/1000)
        res$hits <- res$hits[order(res$hits$log_kd)]
        names(res$hits) <- NULL
      }
      res$cs <- cs
      res$last <- res$time <- Sys.time()
      res$size <- object.size(res$hits)
      res$collection <- input$mirlist
      res$nsel <- nm <- length(selmods())
      res$sel <- ifelse(nm>1,paste(nm,"models"),input$mirnas)
      res$seq <- target()
      res$seqFeature <- input$seqFeature
      res$maxLogKd <- input$maxLogKd
      res$target_length <- nchar(target())
      if(input$subjet_type=="custom"){
        res$target <- "custom sequence"
      }else{
        res$target <- paste0(input$gene, " - ", seltx(),
                            " (", input$seqFeature, ")")
      }
      waiter_hide()
      return(res)
    })

    output$scan_target <- renderText({
      if(is.null(current.cs()) || is.null(cached.hits[[current.cs()]]))
        return(NULL)
      paste("Scan results in: ", cached.hits[[current.cs()]]$target)
    })

    output$cache.info <- renderText({
      if(cache.size()==0) return("Cache empty.")
      paste0(length(cached.checksums()), " results cached (",
             round(cache.size()/1024^2,3)," Mb)")
    })

    output$cached.results <- renderUI({
      ch <- cached.checksums()
      ch2 <- names(ch)
      names(ch2) <- vapply(ch, FUN.VALUE=character(1), FUN=function(x){
        paste0(x$time, ": ", x$sel, " on ", x$target, " (",
               format(x$size,units="Kb"),")")
      })
      radioButtons("selected.cache", "Cached results", choices=ch2)
    })

    observeEvent(input$loadCache, {
      if(is.null(input$selected.cache)) return(NULL)
      current.cs(input$selected.cache)
    })

    observeEvent(input$deleteCache, {
      if(is.null(input$selected.cache)) return(NULL)
      cached.hits[[input$selected.cache]] <- NULL
      if(current.cs()==input$selected.cache) current.cs(NULL)
    })

    output$hits_table <- renderDT({ # prints the current hits
      if(is.null(hits()$hits)) return(NULL)
      h <- as.data.frame(hits()$hits)
      h <- h[,setdiff(colnames(h), c("seqnames","width","strand") )]
      h <- tryCatch(h[order(h$log_kd),], error=function(e) return(h))
      dtwrapper(h, selection="single", callback=JS('
        table.on("dblclick.dt","tr", function() {
          Shiny.onInputChange("dblClickMatch", table.row(this).data()[0]+"/"+Math.random())
          var box = $("#box_match").closest(".box")
          if (box.hasClass("collapsed-box")){
            box.find("[data-widget=collapse]").click();
          }
        })
      '))
    })

    output$dl_hits <- downloadHandler(
      filename = function() {
        if(is.null(hits()$hits)) return(NULL)
        fn <- paste0("hits-", gsub("\\.[09]+", "",
                                   cached.hits[[current.cs()]]$target))
        if(hits()$nsel == 1){
          fn <- paste0(fn,"-",cached.hits[[cs]]$sel,".csv")
        }else{
          fn <- paste0(fn,"-",Sys.Date(),".csv")
        }
        fn
      },
      content = function(con) {
        if(is.null(hits()$hits)) return(NULL)
        h <- as.data.frame(hits()$hits)
        h <- h[,setdiff(colnames(h), c("seqnames","width","strand") )]
        write.csv(h, con, col.names=TRUE)
      }
    )

    observeEvent(input$colHelp, .getHelpModal("hitsCol"))
    observeEvent(input$stypeHelp, .getHelpModal("stypes"))
    observeEvent(input$stypeHelp2, .getHelpModal("stypes"))
    observeEvent(input$manhattanHelp, .getHelpModal("manhattan"))
    observeEvent(input$help_collections, .getHelpModal("collections"))
    observeEvent(input$help_aggregatedHits, .getHelpModal("aggregatedHits"))
    
    output$bartel2009 <- renderImage({
      list(src=system.file("docs", "Bartel2009_sites.png", package="scanMiRApp"),
           contentType = 'image/png', width=772, height=576,
           alt="miRNA sites types from Bartel, Cell 2009")
    })
    
    agghits_data <- reactive({
      if(is.null(hits()$hits)) return(NULL)
      h <- hits()$hits
      ag <- scanMiR::aggregateMatches(h, keepSiteInfo=TRUE)
      ag <- ag[order(ag$repression),]
      ag$transcript <- ag$repression <- NULL
      
      h <- GRanges(rep(as.factor(hits()$target),nrow(h)), IRanges(h$start, h$end))
      mcols(h) <- mcols(hits()$hits)
      ag <- scanMiR::aggregateMatches(h, keepSiteInfo=TRUE)
      ag <- ag[order(ag$repression),]
      ag$transcript <- ag$repression <- NULL
      ag
    })

    output$agghits_table <- renderDT({
      if(is.null(agghits_data())) return(NULL)
      h <- as.data.frame(agghits_data())
      dtwrapper(h)
    })
    
    output$dl_agghits <- downloadHandler(
      filename = function() {
        if(is.null(agghits_data())) return(NULL)
        fn <- paste0("agghits-", gsub("\\.[09]+", "",
                                   cached.hits[[current.cs()]]$target))
        if(hits()$nsel == 1){
          fn <- paste0(fn,"-",cached.hits[[cs]]$sel,".csv")
        }else{
          fn <- paste0(fn,"-",Sys.Date(),".csv")
        }
        fn
      },
      content = function(con) {
        if(is.null(agghits_data())) return(NULL)
        h <- as.data.frame(agghits_data())
        write.csv(h, con, col.names=TRUE)
      }
    )
    
    ## end scan hits and cache

    manhattan_data <- reactive({
      if(is.null(hits()$hits)) return(NULL)
      h <- hits()$hits
      if(length(h)==0) return(NULL)
      h <- h[order(h$log_kd)]
      if(!is.null(h$miRNA) && length(unique(h$miRNA))>input$manhattan_n){
        mirs <- as.character(head(unique(h$miRNA),input$manhattan_n))
        h <- h[h$miRNA %in% mirs]
      }
      if(length(h)==0) return(NULL)
      h
    })

    output$manhattan <- renderPlotly({
      if(is.null(h <- manhattan_data()))
        return(ggplotly(ggplot(), source="manhattan"))
      plotlyObserver$resume()
      sn <- as.character(seqnames(h)[1])
      meta <- metadata(h)
      h <- as.data.frame(h)
      if(!is.null(input$manhattan_ordinal) && input$manhattan_ordinal){
        h$position <- order(h$start)
        xlab <- "Position (ordinal)"
        xlim <- c(1,length(h))
      }else{
        h$position <- round(rowMeans(h[,2:3]))
        xlab <- "Position (nt) in sequence"
        xlim <- c(1,hits()$target_length)
      }
      ael <- list(x="position", y="-log_kd", type="type")
      if("sequence" %in% colnames(h)) ael$seq="sequence"
      if("miRNA" %in% colnames(h)) ael$colour="miRNA"
      p <- ggplot(h, do.call(aes_string, ael))
      ymax <- max(-h$log_kd)
      if(length(selmods())==1){
        mer8 <- get8merRange(selmods()[[1]])/-1000
        ymax <- max(mer8)
        p <- p + geom_rect(aes(colour=NULL),
          data=data.frame(type="8mer range", log_kd=0, position=1),
          xmin=xlim[1], xmax=xlim[2], ymin=min(mer8), ymax=max(mer8),
          alpha=0.2, fill="green")
      }
      p <- p + theme_minimal() + theme(axis.line.x=element_line()) +
        geom_hline(yintercept=-hits()$maxLogKd, linetype="dashed",
                   color="red", size=1) +
        geom_point(size=2) + xlab(xlab) + expand_limits(x=xlim, y=c(0,ymax))
      if(!is.null(h$ORF) && !is.null(meta$tx_info)){
        orflen <- meta$tx_info[sn, "ORF.length"]
        p <- p + geom_vline(xintercept=orflen, color="grey", size=1)
      }
      p <- p + scale_x_continuous(limits=c(0,xlim[2]), expand=c(0,0)) +
        scale_y_continuous(limits=c(0,ymax), expand=c(0,0.1))
      ggplotly(p, source="manhattan")
    })

    selectedMatch <- reactiveVal()

    observeEvent(input$dblClickMatch, {
      if(is.null(hits()$hits)) return(NULL)
      if(is.null(input$dblClickMatch)) return(NULL)
      rid <- as.integer(strsplit(input$dblClickMatch, "/", fixed=TRUE)[[1]][[1]])
      if(is.null(rid) || !(rid>0)) return(NULL)
      h <- hits()$hits
      selectedMatch(h[order(h$log_kd)[rid]])
      showModal(modalDialog(
        title = "Target alignment",
        textOutput("alignment_header"),
        verbatimTextOutput("alignment"),
        easyClose = TRUE,
        footer = NULL
      ))
    })

    plotlyObserver <- observeEvent(event_data("plotly_click", "manhattan",
                                          priority="event"), suspended=TRUE, {
      if(is.null(h <- manhattan_data())) return(NULL)
      event <- event_data("plotly_click", "manhattan")
      if(!is.list(event) || is.null(event$pointNumber)) return(NULL)
      rid <- as.integer(event$pointNumber+1)
      if(is.null(rid) || !(rid>0)) return(NULL)
      if(!is.null(h$miRNA) && length(unique(h$miRNA))>1 &&
         !is.null(event$curveNumber)){
        h <- h[as.integer(droplevels(h$miRNA))==as.integer(event$curveNumber)]
      }
      selectedMatch(h[rid])
      showModal(modalDialog(
        title = "Target alignment",
        textOutput("alignment_header"),
        verbatimTextOutput("alignment"),
        easyClose = TRUE,
        footer = NULL
      ))
    })

    output$alignment_header <- renderText({
      if(is.null(m <- selectedMatch()))
        return("Double-click on a row of the table above to visualize it here")
      miRNA <- ifelse("miRNA" %in% colnames(mcols(m)),
                      as.character(mcols(m)$miRNA),hits()$sel)
      paste0(miRNA, " match at ",start(m),"-",end(m)," (", mcols(m)$type, ")")
    })

    output$alignment <- renderPrint({
      if(is.null(m <- selectedMatch())) return(NULL)
      mir <- ifelse("miRNA" %in% colnames(mcols(m)),
                    as.character(m$miRNA), hits()$sel)
      mod <- modlists[[hits()$collection]][[as.character(mir)]]
      seqs <- hits()$seq
      seqs <- setNames(as.character(seqs), as.character(seqnames(m)))
      viewTargetAlignment(m, mod, seqs=seqs)
    })

    ##############################
    ## miRNA-centric tab

    mod <- reactive({ # the currently-selected KdModel
      if(is.null(allmods()) || is.null(input$mirna)) return(NULL)
      allmods()[[input$mirna]]
    })

    output$modconservation <- renderText({
      if(is.null(mod())) return(NULL)
      as.character(conservation(mod()))
    })

    output$mirbase_link <- renderUI({
      tags$a(href=paste0("http://www.mirbase.org/textsearch.shtml?q=",
                         input$mirna),
             icon("external-link"), "miRBase", target="_blank")
    })

    output$modplot <- renderPlot({ # affinity plot
      if(is.null(mod())) return(NULL)
      plotKdModel(mod())
    })

    output$targets_ui <- renderUI({
      if(is.null(annotations[[input$mirlist]]$aggregated)){
        return(tags$p("Targets not accessible ",
                      "(no pre-compiled scan available)"))
      }
      list(
        fluidRow(
          column(5, tags$p("Double-click on a row to visualize hits.")),
          column(4, checkboxInput("targetlist_gene",
                                  "Only top transcript per gene",value=FALSE)),
          column(3, actionButton("stypeHelp2","Site types",
                                 icon=icon("question-circle")))
        ),
        withSpinner(DTOutput("mirna_targets")),
        downloadLink('dl_mirTargets', label = "Download all")
      )
    })

    txs <- reactive({ # the tx to gene symbol table for the current annotation
      if(is.null(input$mirlist) || input$mirlist=="" ||
         !(input$mirlist %in% names(annotations))) return(NULL)
      db <- annotations[[input$mirlist]]$ensdb
      if(is.null(db)) return(NULL)
      if(is(db,"EnsDb")){
        tx <- mcols(transcripts(db, c("tx_id","gene_id","tx_biotype")))
        tx <- merge(tx,mcols(genes(db, c("gene_id","symbol"))), by="gene_id")
        tx <- as.data.frame(tx[,c("symbol","tx_id","tx_biotype")])
      }else{
        tx <- mcols(transcripts(db, c("gene_id","tx_name","TXTYPE")))
        colnames(tx) <- c("gene","tx_id","tx_biotype")
      }
      tx
    })

    mirtargets_prepared <- reactive({
      if(is.null(preTargets <- annotations[[input$mirlist]]$aggregated) ||
         !(input$mirna %in% names(preTargets))) return(NULL)
      d <- preTargets[[input$mirna]]
      d$repression <- d$repression/1000
      if(!is.null(annotations[[input$mirlist]]$addDBs)){
        for(f in names(annotations[[input$mirlist]]$addDBs)){
          x <- annotations[[input$mirlist]]$addDBs[[f]]
          x <- x[x$miRNA==input$mirna,]
          row.names(x) <- x$transcript
          d[[f]] <- x[as.character(d$transcript),"score"]
        }
      }
      if(!is.null(txs())){
        d <- merge(txs(), d, by.x="tx_id", by.y="transcript")
        colnames(d) <- gsub("tx_id", "transcript", colnames(d))
        if(input$targetlist_gene){
          d <- d[order(d$repression),]
          d <- d[!duplicated(d$symbol),]
        }
      }
      as.data.frame(d[order(d$repression),])
    })

    output$mirna_targets <- renderDT({
      d <- mirtargets_prepared()
      if(is.null(d)) return(NULL)
      colnames(d) <- gsub("^n\\.","",colnames(d))
      dtwrapper(d, selection="single", callback=JS('
      table.on("dblclick.dt","tr", function() {
        Shiny.onInputChange("dblClickSubject", table.row(this).data()[1])
      })
    '))
    })

    ## double-click on a transcript in miRNA targets:
    observeEvent(input$dblClickSubject, {
      sub <- input$dblClickSubject
      if(input$targetlist_gene) return(NULL)
      gene <- getGeneFromTx(sel_ensdb(), sub)
      isolate(updateSelectizeInput(session, "gene", selected=gene,
                           choices=allgenes(), server=TRUE))
      updateTabItems(session, "subject_type", "transcript")
      txs <- getTxs(sel_ensdb(), gene=gene)
      #updateCheckboxInput(session, "utr_only", value=input$targetlist_utronly)
      updateSelectizeInput(session, "transcript", selected=sub, choices=txs)
      updateSelectizeInput(session, "mirnas", selected=input$mirna)
      #updateTabItems(session, "main_tabs", "tab_subject")
      newflag <- changeFlag()+1
      changeFlag(newflag)
      observe({
        tmp <- changeFlag()
        cs <- checksum()
        cached.hits[[cs]] <- do.scan()
        current.cs(cs)
      })
      updateTabItems(session, "main_tabs", "tab_hits")
    })

    output$dl_mirTargets <- downloadHandler(
      filename = function() {
        if(is.null(input$mirna)) return(NULL)
        paste0(input$mirna, "targets.csv")
      },
      content = function(con) {
        write.csv(mirtargets_prepared(), con, col.names=TRUE)
      }
    )

    output$pkgVersions <- renderText({
      paste(
        "Running on scanMiR", packageVersion("scanMiR"), "and scanMiRApp",
        packageVersion("scanMiRApp")
      )
    })

    waiter_hide()
  }
}


#' scanMiRApp
#' A wrapper for launching the scanMiRApp shiny app
#'
#' @param annotations A named list of \code{\link{ScanMiRAnno}} objects. If
#' omitted, will use the base ones.
#' @param ... Passed to \code{\link{scanMiRserver}}
#'
#' @return A shiny app
#' @export
#' @examples
#' if(interactive()){
#'   anno <- ScanMiRAnno("fake")
#'   scanMiRApp(list(fakeAnno=anno))
#' }
scanMiRApp <- function(annotations=NULL, ...){
  if(is.null(annotations)){
    an <- c("GRCh38","GRCm38","Rnor_6")
    message("Loading annotations for ", paste(an, collapse=", "))
    annotations <- lapply(an, FUN=ScanMiRAnno)
  }
  shinyApp(scanMiRui(), scanMiRserver( annotations = annotations, ... ))
}
