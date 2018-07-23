package com.rhino.mcfinn.swimmer.purchasing
{
  import com.rhino.util.Log;

  public class ProductData
  {
    /**************************************************************************
     * INSTANCE PROPERTIES
     **************************************************************************/
    
    private var mProductId:String;
    private var mTitle:String;
    private var mDescription:String;
    private var mType:uint;
    private var mLocalizedPrice:String;
    private var mPrice:Number;
    private var mCurrencyCode:String;
    private var mSubscriptionMonthCount:uint;
    
    /**************************************************************************
     * INSTANCE CONSTRUCTOR
     **************************************************************************/
    
    public function ProductData(productId:String, title:String, description:String, type:uint, localizedPrice:String, price:Number, currencyCode:String, subscriptionMonthCount:uint=0)
    {
      mProductId = productId;
      mTitle = title;
      mDescription = description;
      mType = type;
      mLocalizedPrice = localizedPrice;
      mPrice = price;
      mCurrencyCode = currencyCode;
      mSubscriptionMonthCount = subscriptionMonthCount;
    }

    /**************************************************************************
     * INSTANCE METHODS - READ ONLY ACCESSORS
     **************************************************************************/
    
    /**
     * unique product ID, platform dependent
     */ 
    public function get productId():String { return mProductId; }
    
    /**
     * product title
     */
    public function get title():String { return mTitle; }
    
    /**
     * product description
     */
    public function get description():String { return mDescription; }
    
    /**
     * a valid TYPE_ constant
     */
    public function get type():uint { return mType; }
    
    /**
     * localized price string, i.e. '$0.99'
     */
    public function get localizedPrice():String { return mLocalizedPrice; }
    
    /**
     * price as a floating point number
     */
    public function get price():Number { return mPrice; }
    
    /**
     * ISO 4217 three character currency code, i.e. 'USD', 'EUR', 'CAD'
     */
    public function get currencyCode():String { return mCurrencyCode; }
    
    /**
     * the month count for TYPE_SUBSCRIPTION products
     */
    public function get subscriptionMonthCount():uint { return mSubscriptionMonthCount; }
    
    /**************************************************************************
     * INSTANCE METHODS - SUBSCRIPTIONS
     **************************************************************************/
    
    /**
     * For a subscription product, returns a duration description string
     * Example: "1 Month" or "3 Months"
     */
    public function get subscriptionDurationText():String
    {
      return mSubscriptionMonthCount + ' ' + ((mSubscriptionMonthCount>1) ? 'Months' : 'Month')
    }
    
    /**
     * For a subscription product, returns a string indicating the price per month.
     * Example: "$3.99" or "2.49 EUR"
     */
    public function get subscriptionLocalizedPricePerMonth():String
    {
      var prccts:int = (mPrice / mSubscriptionMonthCount) * 100; // truncate trailing decimal places; price in "cents"
      var prcdls:Number = Number(prccts) / 100;
      return ((currencyCode=='USD') ? '$'+prcdls : prcdls+' '+currencyCode);
    }
    
    /**
     * For a subscription product, returns a string with the full price and full duration.
     * Example: "$14.99 recurring every 3 months"
     */
    public function get subscriptionRecurringDetailText():String
    {
      return mLocalizedPrice + ' recurring every ' + ((mSubscriptionMonthCount>1) ? mSubscriptionMonthCount + ' months' : 'month');
    }
    
    /**************************************************************************
     * INSTANCE METHODS - UTILITY
     **************************************************************************/
    
    public function log():void
    {
      Log.out("product: " + mProductId);
      Log.out("  title  . . . . . . . . . . . " + mTitle);
      Log.out("  description  . . . . . . . . " + mDescription);
      Log.out("  type . . . . . . . . . . . . " + mType);
      Log.out("  localized price  . . . . . . " + mLocalizedPrice);
      Log.out("  price  . . . . . . . . . . . " + mPrice);
      Log.out("  currency code  . . . . . . . " + mCurrencyCode);
      Log.out("  subscription month count . . " + mSubscriptionMonthCount);
    }
    
    /**************************************************************************
     * STATIC PROPERTIES
     **************************************************************************/
    
    public static const TYPE_NON_CONSUMABLE   :uint = 0;
    public static const TYPE_CONSUMABLE       :uint = 1;
    public static const TYPE_SUBSCRIPTION     :uint = 2;
    
    /**************************************************************************
     * STATIC METHODS
     **************************************************************************/
    
  }
}