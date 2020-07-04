---
title: "Vlookup in R AND Python"
date: "2020-06-03T22:12:03.284Z"
template: "post"
draft: false
slug: "vlookup-in-r-python"
category: "tips"
tags:
  - "python"
  - 'r'
  - 'join'
description: "If your moving into R or python from excel than you know what I am talking about. If python/R/SQL where you first tool for data analysis than you will never understand the pain."
socialImage: "/media/join.png"
---

If your moving into R or python from excel than you know what I am talking about. If python/R/SQL where you first tool for data analysis than you will never understand the pain.  
  
Vlookup or index/match are basic building block of excel data analysis and reporting.  
  
First question while using R was how the hell will I use Vlookup in R?_(All my report had vlookup at least one time, and also I was naive and didn't understood the concept of relation databases) ._ I googled it, answers were not lucid. If you google it most probability you will come across use **_merge as answer._** Merge is base function in R, like most base function_(except very few)_ it complected to use. Plus most excel user are not that familiar with relationship i,e relation database (there might be few exception if you use pivot table a lot) , for them info in each cell are different. Excel user never think data as column, info in each cell is separate for them. We (excel user) thinking about how we will add two cell, how will we look value of cell A1 on table B1:C10. We never think as lets look value of column A into table B:C. or add column A to B.  
  
_**Advice:** If you come from excel background start thinking all data as column  and starts respecting the structure of data. In excel you can add any two cells (A1 and A5) and put that somewhere in  C5, have different type of data in one column(like number in A1, date A2, string in third ). Always think any operation as column operation not cells operation. Like if you have to add two series, put it under different column and add these to make third column. Any analysis, reporting, manipulation only consists of joining column and than summarizing(visualization, modeling)._  
**Lets break down Vlookup,**  
_Vlookup - takes a value say "A" than find that value "A" in next table than pull info related to "A" from  this table._  
This is called joining in database and R, you take list of value and join(match these value in next table) and pull info related to these value.  
  
**lets take an example**   
```r
##make data frame
master <-  data.frame(ID = 1:50, name = letters[1:50],
date = seq(as.Date("2016-01-01"), by = "week", len = 50))
df = pd.DataFrame
```

We have different list which only has id
```r
##lookup valuer
lookup =data.frame(id =  c(23, 50, 4, 45))
```

Now we need to look up name of these id in master data.frame.

Install dplyr  and load R or pandas in python
```r
##load dplyr
required(dplyr)
```
dplyr has many user friendly join function.  
![join](/media/join.png)

lets get back to problem
```r
##lookup
id_lookup = left_join(id, master, by="id") # output are only value that 
                          >matches to id_lookup, if no match is found it return as NA
or
id_lookup = right_join(master, id, by="id") ##both column should have common name
```

If column name are different you can

```r
##If column name are different you can
id_lookup = right_join(master, id, by=c("id"="id2"))
```

or rename column using
```r
colnames(id)[x]  = "id"   # x is cloumn index
id_lookup = rename(id, id=id2)  # rename is dplyr function
```

New id_lookup will have colnames as "id","name","date". If you don't need date you can always make subset of dataframe. Or before join make subset of master
```r
##subset of data

id_lookup = id_lookup[ , -c("date")]
or
id_lookup = id_lookup[ , c("id", "date")
or
id_lookup = id_lookup[,c(1,3)]
or
id_lookup = subset(id_lookup, condition, select=c("id", "date"))
```

Get used to with joins, these are all joins you we need to perform any lookup. You never perform look for only particular value only, its always column look up. Best practices is always make data.frame of what you have to look up and  join to next table. 

> "Reputation is like fine china, expensive to acquire, and easily broken. If you are not sure if something is right or wrong, consider whether you’d want it reported in the morning paper."
>
> --Alice Schroeder, The Snowball: Warren Buffett and the Business of Life