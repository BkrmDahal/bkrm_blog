---
title: Building Ranking Algorithm
date: "2020-06-04T22:12:03.284Z"
template: "post"
draft: false
slug: "building-ranking-algorithm"
category: "algorithm"
tags:
  - "thinking"
  - 'algorithm'
description: "Combine mutiple algorithum to rank products. Generally websites rank base on newest or popular product, but this method has more cons than pros. Ranking is omnipresent from newsletter to ads."
socialImage: "/media/DN-Blog-Ranking-Algorithm.jpg"
---

![BUILDING THE RANKING ALGORITHM](/media/DN-Blog-Ranking-Algorithm.jpg)

How to rank the product feed for user?  
This is multi-millioner question. Everyone would love to rank the product like Facebook ranks news/update but this is not viable for majority of business. Generally websites rank base on newest or popular product, but this method has more cons than pros. Ranking is omnipresent from newsletter to ads and as data scientist I have always struggle to develop the ranking algorithm due all issue like feedback effect(cycle of top product getting top spot and more order), long tail(80/20 rule) and multiple factor to consider. After reading tons of article, research paper and carry out multiple A/B testing , here is my final strategy:  
  
We want product feed to have combination of 3 variety of  product, latest, popular and trending. I calculated all three score separately for each product, normalize them and than combine them using one of strategy stated below.  
  
### Get the score: 
**1\. Latest\_score:** Do we take liner scale for age of product or log scale or gravity like [hacker news](https://medium.com/hacking-and-gonzo/how-hacker-news-ranking-algorithm-works-1d9b0cf2c08d), it all depends on your product. E.g for Reddit today news is most important, any news older than than a day is not relevant until and unless it very popular, for his case log scale or scale with high gravity is useful. But for job portal, job that are week old may be still relevant and liner scale with low gravity may be useful.  
  
**2\. Popularity\_score:** You want to show popular product at top but still not let top 1% of product which account for large volume of sales or traffic to dominant. You can used similar strategy with lastest\_score, take log based of any based or used gravity to minimize the effect.  
  
**3\. Trending\_score:** Best way to find trending product is to find conversion ratio of any product ( conversion ratio may be purchase or click, its no\_of\_desired\_action/ total\_visit). You could use CVR but CVR are sensitive as few product with low page view may have high CVR. So I calculated [Wilson score](https://en.wikipedia.org/wiki/Binomial_proportion_confidence_interval) for CVR, [Reddit uses it](https://medium.com/hacking-and-gonzo/how-reddit-ranking-algorithms-work-ef111e33d0d9)(Wilson score is mostly used when you have positive feedback and negative feedback. For CVR, we consider positive feedback and those visit that lead to desired action or negative feedback as those visit that didn't lead to desired action) . Its simple but elegant. Best things about Wilson Score is it auto adjusts, i.e if you have product with low page view but high CVR than it will be ranked at top but if it cant maintain the CVR , Wilson score decrease. I also like using [beta distrubation](https://en.wikipedia.org/wiki/Beta_distribution) probability value to make CVR more robust in-place of Wilson Score.  
  
### How to combine these scores?
**First Strategy:** Normalized all score and give certain weight to each score. E.g _0.33\*latest + 0.33\*popular+0.33\*trending +0.01\*random_ or _popular/latest + trending._   
**Second Strategy:**  Predefine no of slots for each strategy and repeat i,e put 2 popular item followed by 2 trending followed by 2 latest.  
  
### How to findbest weight or best slots number for each strategy?
Domain expertise along with  numerous A/B test or [interleaving](https://medium.com/netflix-techblog/interleaving-in-online-experiments-at-netflix-a04ee392ec55) is value resources to find best weight or slot numbers. It will take time to get the best weight, don't lose patience.  
  
> Note: I have left personalize  recommendation here, I will write more blog on how to added personal recommendation(Content and collaborative filtering) score in future blog post.
  
Quote from book I am reading:  

> _“Introverts, in contrast, may have strong social skills and enjoy parties and business meetings, but after a while wish they were home in their pajamas. They prefer to devote their social energies to close friends, colleagues, and family. They listen more than they talk, think before they speak, and often feel as if they express themselves better in writing than in conversation. They tend to dislike conflict. Many have a horror of small talk, but enjoy deep discussions.”_ 
> 
> __― Susan Cain, Quiet: The Power of Introverts in a World That Can't Stop Talking__