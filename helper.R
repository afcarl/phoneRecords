#!/usr/bin/env Rscript

library(shiny)
library(DT)
library(tools)
library(magrittr)
library(dplyr)
library(stringr)
library(ggplot2)
library(scales)
library(igraph)

aggTable <- function(data) {
  if ("Direction" %in% names(data)) {
    x1 <- data %>% filter(Direction == 'Outgoing') %>%
      group_by(Target, Number_Dialed) %>%
      summarise(Outgoing = n())
    names(x1) <- c('Target', 'Number_Dialed', 'Outgoing')
    x2 <- data %>% filter(Direction == 'Incoming') %>% group_by(Target, Number_Dialed) %>%
                summarise(Incoming = n())
    names(x2) <- c('Target', 'Number_Dialed', 'Incoming')
    dat <- full_join(x1, x2)
  } else {
    dat <- data %>% group_by(Target, Number_Dialed) %>%
      summarise(Number_Of_Calls = n())
  }
  return(dat)
}

parseAttTextBlock1 <- function(textBlock, pageNumber) {
  target <- grep("Voice Usage For: ", textBlock, value=T) %>%
    str_extract(., "\\([0-9]{3}\\)[0-9]{3}.[0-9]{4}") %>%
    gsub("\\(|\\)|-", "", .) %>%
    paste("1", ., sep='')

  #Block off call logs
  callLogStart <- ifelse(any(grepl("^\\(UTC\\)$", textBlock)),
                         grep("^\\(UTC\\)$", textBlock) + 1,
                         grep("[0-9]+(?=\\s+[0-9]{2}/[0-9]{2}/[0-9]{2})", textBlock, perl=T))
  callLogFinish <- grep("AT&T\\s+Proprietary", textBlock) - 1

  #Get index of each call record so we can later parse out what we don't need
  #Check to see if call records are all in one block
  if (grep("Item\\s+Conn", textBlock) == callLogStart) {
    itemNumbers <- dates <- times <- durations <- directions <- numbersDialed <- flagNumbers <- NA
    flags <- paste("Error found on page", pageNumber, sep=' ')
  } else {
    callRecordIDX <- grep("[0-9]+(?=\\s+[0-9]{2}/[0-9]{2}/[0-9]{2})", textBlock, perl=T)

    #Initialize variables
    itemNumbers <- dates <- times <- durations <- directions <- numbersDialed <- flags <- flagNumbers <- NULL

    for (i in 1:length(callRecordIDX)) {
      idx <- callRecordIDX[i]
      itemNumber <- str_extract(textBlock[idx], "[0-9]+(?=\\s+[0-9]{2}/[0-9]{2}/[0-9]{2})")
      date <- str_extract(textBlock[idx], "[0-9]{2}/[0-9]{2}/[0-9]{2}")
      duration <- str_extract_all(textBlock[idx], "[0-9]{1,2}:[0-9]{2}")[[1]][3]
      time <- str_extract_all(textBlock[idx], "[0-9]{1,2}:[0-9]{2}")[[1]][1]
      originating <- str_extract_all(textBlock[idx], "[0-9]{11}")[[1]][1]
      terminating <- str_extract_all(textBlock[idx], "[0-9]{11}")[[1]][2]
      direction <- ifelse(originating == target, "Outgoing", "Incoming")
      numberDialed <- ifelse(originating == target, terminating, originating)

      #Check for additional numbers listed below that may be flagged with codes
      if (i != length(callRecordIDX)) {
        if ((callRecordIDX[i + 1] - callRecordIDX[i]) > 1) {
          callRecordStart <- callRecordIDX[i] + 1
          callRecordFinish <- callRecordIDX[i + 1] - 1
        }
      } else {
        if ((grep("AT&T\\s+Proprietary", textBlock) - callRecordIDX[i]) > 1) {
          callRecordStart <- callRecordIDX[i] + 1
          callRecordFinish <- grep("AT&T\\s+Proprietary", textBlock) - 1
        }
      }

      if (exists("callRecordStart")) {
        line <- textBlock[callRecordStart:callRecordFinish] %>% paste(collapse=' ')
        if (grepl("[0-9]{7,}\\(F\\)", line)) {
          flag <- "F"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else if (grepl("[0-9]{7,}\\(D\\)", line)) {
          flag <- "D"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else if (grepl("[0-9]{7,}\\(OO\\)", line)) {
          flag <- "OO"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else {
          flag <- ""
          flagNumber <- NA
        }
      } else {
        flag <- ""
        flagNumber <- NA
      }
      itemNumbers <- c(itemNumbers, itemNumber)
      dates <- c(dates, date)
      times <- c(times, time)
      durations <- c(durations, duration)
      directions <- c(directions, direction)
      numbersDialed <- c(numbersDialed, numberDialed)
      flags <- c(flags, flag)
      flagNumbers <- c(flagNumbers, flagNumber)
    }
  }
  dataRows <- data.frame("Target"=target, "Item"=itemNumbers, "Date"=dates, "Time"=times,
                   "Duration"=durations, "Direction"=directions,
                   "Number_Dialed"=numbersDialed, "Flag"=flags, "Flagged_Number"=flagNumbers,
                   stringsAsFactors=F)

  return(dataRows)
}

parseAttTextBlock2 <- function(textBlock) {
  target <- grep("Voice Usage For: ", textBlock, value=T) %>%
    str_extract(., "\\([0-9]{3}\\)[0-9]{3}.[0-9]{4}") %>%
    gsub("\\(|\\)|-", "", .) %>%
    paste("1", ., sep='')

  #Block off call logs
  callLogStart <- ifelse(any(grepl("^\\(UTC\\)$", textBlock)),
                         grep("^\\(UTC\\)$", textBlock) + 1,
                         grep("[0-9]+(?=,[0-9]{2}/[0-9]{2}/[0-9]{2})", textBlock, perl=T))
  callLogFinish <- grep("AT&T\\s+Proprietary", textBlock) - 1

  #Get index of each call record so we can later parse out what we don't need
  #Check to see if call records are all in one block
  if (grep("Item[,]?Conn(?=.*)", textBlock, perl=T) == callLogStart) {
    itemNumbers <- dates <- times <- durations <- directions <- numbersDialed <- flagNumbers <- NA
    flags <- "Error found. Some data missing."
  } else {
    callRecordIDX <- grep("[0-9]+(?=,[0-9]{2}/[0-9]{2}/[0-9]{2})", textBlock, perl=T)

    #Initialize variables
    itemNumbers <- dates <- times <- durations <- directions <- numbersDialed <- flags <- flagNumbers <- NULL

    for (i in 1:length(callRecordIDX)) {
      idx <- callRecordIDX[i]
      crd <- strsplit(textBlock[idx], ",")[[1]]
      itemNumber <- crd[1]
      date <- strsplit(crd[2], " ")[[1]][1]
      time <- strsplit(crd[2], " ")[[1]][2]
      duration <- crd[6]
      originating <- crd[4]
      terminating <- crd[5]
      direction <- ifelse(originating == target, "Outgoing", "Incoming")
      numberDialed <- ifelse(originating == target, terminating, originating)

      #Check for additional numbers listed below that may be flagged with codes
      if (i != length(callRecordIDX)) {
        if ((callRecordIDX[i + 1] - callRecordIDX[i]) > 1) {
          callRecordStart <- callRecordIDX[i] + 1
          callRecordFinish <- callRecordIDX[i + 1] - 1
        }
      } else {
        if ((grep("AT&T\\s+Proprietary", textBlock) - callRecordIDX[i]) > 1) {
          callRecordStart <- callRecordIDX[i] + 1
          callRecordFinish <- grep("AT&T\\s+Proprietary", textBlock) - 1
        }
      }

      if (exists("callRecordStart")) {
        line <- textBlock[callRecordStart:callRecordFinish] %>% paste(collapse=' ')
        if (grepl("[0-9]{7,}\\(F\\)", line)) {
          flag <- "F"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else if (grepl("[0-9]{7,}\\(D\\)", line)) {
          flag <- "D"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else if (grepl("[0-9]{7,}\\(OO\\)", line)) {
          flag <- "OO"
          flagNumber <- str_extract(line, "[0-9]{7,}")
        } else {
          flag <- ""
          flagNumber <- NA
        }
      } else {
        flag <- ""
        flagNumber <- NA
      }
      itemNumbers <- c(itemNumbers, itemNumber)
      dates <- c(dates, date)
      times <- c(times, time)
      durations <- c(durations, duration)
      directions <- c(directions, direction)
      numbersDialed <- c(numbersDialed, numberDialed)
      flags <- c(flags, flag)
      flagNumbers <- c(flagNumbers, flagNumber)
    }
  }
  dataRows <- data.frame("Target"=target, "Item"=itemNumbers, "Date"=dates, "Time"=times,
                         "Duration"=durations, "Direction"=directions,
                         "Number_Dialed"=numbersDialed, "Flag"=flags, "Flagged_Number"=flagNumbers,
                         stringsAsFactors=F)

  return(dataRows)
}

prepCSV <- function(data) {
  names(dat) <- names(dat) %>% tolower()
  vars <- names(dat)
  if ("date" %in% vars & !("time" %in% vars)) {

  if ("originating" %in% vars) {
    direction <- ifelse(dat$originating == dat$target, "Outgoing", "Incoming")
    if (!("number_dialed" %in% vars)){
      numberDialed <- ifelse(originating == target, terminating, originating)
    }
  }
  }
}

plotGraph <- function(data, target, month, year) {
  monNames <- c('January', 'February', 'March', 'April', 'May', 'June',
                 'July', 'August', 'September', 'October', 'November', 'December')
  monDigits <- c('01', '02', '03', '04', '05', '06', '07', '08', '09', 10:12)
  endDays <- c(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)

  idx <- which(monNames == month)

  if (!("Direction" %in% names(data))) data$Direction <- "Total"
  data$Date %<>% as.Date(format="%m/%d/%y")
  startDate <- paste0(year, '-', monDigits[idx], '-01') %>% as.Date()
  endDate <- paste0(year, '-', monDigits[idx], '-', endDays[idx]) %>% as.Date()
  plotData <- data %>%
    filter(between(Date, startDate, endDate)) %>%
    group_by(Date, Direction) %>%
    summarise(Freq=n())

  plotTitle <- paste0('No. of Calls by Day for ', target, ' in ', month, ' ', year)
  yMax <- max(plotData$Freq)
  yMax <- ceiling(yMax/10) * 10 + 10

  p <- ggplot(data=plotData, aes(x=Date, y=Freq, fill=Direction)) +
    geom_bar(stat='identity') +
    labs(x='Date', y='Count', title=plotTitle) +
    theme_bw() +
    theme(axis.text.x = element_text(angle=90, vjust=-0.0001),
          axis.title.x = element_text(vjust = -0.25, size=rel(1.1)),
          axis.title.y = element_text(vjust = 1.2, size=rel(1.1)),
          panel.grid.minor = element_blank(),
          plot.title = element_text(vjust=1.6),
          legend.position='bottom',
          legend.title=element_blank()) +
    scale_x_date(labels=date_format("%a %d"),
                 breaks=date_breaks("day"),
                 expand=c(-0.02, 0.9)) +
    scale_y_continuous(limits=c(0, yMax), breaks=seq(from=0, to=yMax, by=5)) +
    scale_fill_manual(values=c('light blue', 'light green'))

  return(p)
}

formatNumber <- function(number) {
  if (nchar(number) >= 7) {
    if (nchar(number) == 11) {
      tmp <- substr(number, 2, 11)
    } else if (nchar(number) == 10) {
      tmp <- substr(number, 1, 10)
    } else if (nchar(number) == 7) {
      tmp <- substr(number, 1, 7)
    } else {
      tmp <- number
    }
    newNumber <- paste("(", substr(tmp, 1, 3), ") ", substr(tmp, 4, 6), "-", substr(tmp, 7, 10), sep='')
  } else {
    newNumber <- number
  }
  return(newNumber)
}

generateNetwork <- function(data) {
  filteredData <- data %>% filter(!is.na(Number_Dialed))
  networkData <- filteredData %>% group_by(Target, Number_Dialed) %>%
    summarise(Count=n()) %>% arrange(Number_Dialed)
  networkData <- networkData %>% group_by(Number_Dialed) %>% summarise(Count=n())
  numbersOfInterest <- networkData %>% filter(Count >= 2) %>% select(Number_Dialed) %>%
    unlist() %>% unname()
  filteredNetworkData <- filteredData %>% filter(Number_Dialed %in% numbersOfInterest) %>%
    group_by(Target, Number_Dialed) %>% select(Target, Number_Dialed)
  if (nrow(filteredNetworkData) == 0) return(NULL) else return(filteredNetworkData)
}

generateRandomDate <- function(n=500) {
st <- "2010/01/02" %>% as.Date() %>% as.POSIXct()
et <- "2015/05/31" %>% as.Date() %>% as.POSIXct()
dt <- as.numeric(difftime(et,st,unit="sec"))
ev <- sort(runif(n, 0, dt))
rt <- st + ev
return(as.Date(rt))
}

generateRandomPhoneNumber <- function(n=500) {
  prefix <- "(123) 555-"
  suffix <- sample(1:9999, n, replace=T) %>% str_pad(., 4, pad="0")
  number <- paste(prefix, suffix, sep='')
  return(number)
}

generateExampleData <- function() {
  Target <- c(rep('(123) 555-0123', 125), rep('(123) 555-1580', 125),
              rep('(123) 555-8142', 125), rep('(123) 555-9329', 125))
  Number_Dialed <- generateRandomPhoneNumber()
  Number_Dialed <- ifelse(Number_Dialed %in% Target, "(123) 555-6565", Number_Dialed)
  Date <- generateRandomDate()
  Direction <- sample(c('Outgoing', 'Incoming'), 500, replace=T)
  Duration <- paste("0", sample(0:9, 500, replace=T), ":", sample(10:59, 500, replace=T), sep='')
  exampleData <- data.frame("Target"=Target, "Number_Dialed"=Number_Dialed,
                            "Date"=Date, "Direction"=Direction, "Duration"=Duration, stringsAsFactors=F)
  return(exampleData)
}



