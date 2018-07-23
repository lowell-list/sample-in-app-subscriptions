package com.rhino.mcfinn.swimmer.purchasing
{
  import com.rhino.mcfinn.swimmer.data.AnalyticsTracker;
  import com.rhino.mcfinn.swimmer.data.GameData;
  import com.rhino.mcfinn.swimmer.display.starling.overlays.dialogs.Alert;
  import com.rhino.util.Log;
  
  import feathers.data.ListCollection;
  
  import org.osflash.signals.Signal;

  /**
   * A multi-platform manager to handle Swim & Play purchasing details.
   */
  public class PurchaseManager
  {
    /**************************************************************************
     * INSTANCE PROPERTIES
     **************************************************************************/
    
    protected var mSubscriptionStatusChanged:Signal;
    protected var mNonConsumablePurchased:Signal;
    protected var mSingleUnlockPurchased:Signal;
    
    private var mLoadingAlert:Alert = null;
    
    /**************************************************************************
     * INSTANCE CONSTRUCTOR (SINGLETON)
     **************************************************************************/
    
    public function PurchaseManager()
    {
      // singleton pattern
      if(sInstance) { throw new Error("Singleton... use instance()"); }
      
      mSubscriptionStatusChanged = new Signal(Boolean);
      mNonConsumablePurchased = new Signal(String);
      mSingleUnlockPurchased = new Signal();
    }

    /**************************************************************************
     * INSTANCE METHODS - SIGNAL ACCESSORS
     **************************************************************************/
    
    /**
     * Dispatched when the subscription status has changed.
     * Listener form: function(isCurrent:Boolean):void
     */
    public function get subscriptionStatusChanged():Signal { return mSubscriptionStatusChanged; }
    
    /**
     * Dispatched when a non-consumable product has been purchased.
     * Listener form: function(productId:String):void
     */
    public function get nonConsumablePurchased():Signal { return mNonConsumablePurchased; }
    
    /**
     * Dispatched when the single unlock product has been purchased.
     * Listener form: function():void
     */
    public function get singleUnlockPurchased():Signal { return mSingleUnlockPurchased; }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - GENERAL
     **************************************************************************/
    
    /**
     * Restores transactions for the user on this device.
     */
    public function restoreTransactions():void { /* override */ }
    
    /**
     * Loads product information.
     * 
     * @param onDone      (optional) Callback function of the form: onDone(products:Vector.<ProductData>):void
     * @param refresh     (optional) If true, then all products are reloaded from the server
     */
    public function loadProducts(onDone:Function=null, refresh:Boolean=true):void { /* override */ }
    
    /**
     * Initiates a new purchase.
     * 
     * @param productData   Indicates the product to purchase.
     */
    public function purchaseProduct(productData:ProductData):void { /* override */ }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - SUBSCRIPTION
     **************************************************************************/
    
    /**
     * Indicates if subscriptions are supported on the current platform.
     */
    public function subscriptionsSupported():Boolean { /* override */ return false; }
    
    /**
     * Checks if the subscription associated with the user on this device is current.
     * 
     * @param onDone      (optional) Callback function of the form: onDone(isCurrent:Boolean):void
     *                    The isCurrent parameter will be true if the subscription is current; false otherwise
     * @param refresh     (optional) If true, then the subscription status will be refreshed from the server.
     *                    Otherwise an unexpired cached value may be used.
     */
    public function isSubscriptionCurrent(onDone:Function=null, refresh:Boolean=false):void {
      /* override */
      if(onDone!=null) { onDone(false); }
    }
    
    /**
     * Displays UI that allows the user to manage subscriptions.
     */
    public function manageSubscriptions():void { /* override */ }
    
    /**
     * Returns subscription "Fine Print" text.  Override to customize.
     */
    public function getSubscriptionFinePrint1():String { return 'Subscriptions automatically renew unless canceled. Prices subject to change.'; }
    
    /**
     * Returns subscription "Fine Print" text.  Override to customize.
     */
    public function getSubscriptionFinePrint2():String { return ''; /* override */ }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - SINGLE UNLOCK IAP
     **************************************************************************/
    
    /**
     * Indicates if a single unlock IAP is supported on the current platform.
     */
    public function singleUnlockSupported():Boolean { /* override */ return false; }
    
    /**
     * @return true if the single unlock IAP has been purchased; false otherwise
     */
    public function isSingleUnlockPurchased():Boolean {
      return GameData.instance.preferences.getBoolean(GameData.PRFNAM_SINGLE_UNLOCK_PURCHASED,false);
    }
    
    /**
     * Checks if the given product is the Single Unlock product.
     */
    public function isSingleUnlockProduct(productData:ProductData):Boolean { /* override */ return false; }
    
    /**************************************************************************
     * INSTANCE METHODS - INTERNAL - SUBSCRIPTION
     **************************************************************************/
    
    /**
     * Applies a new subscription status.  Called internally by a subclass.
     * 
     * mOnSubscriptionStatusChangedSignal is dispatched if the subscription status changes.
     * The onDone callback is called if supplied.
     * 
     * @param newStatus               The new subscription status: true if active/current, false if not
     * @param message                 (optional) a detail message describing why the subscription status has changed
     * @param onDone                  (optional) Callback function of the form: onDone(isCurrent:Boolean):void
     *                                           The isCurrent parameter will match the newStatus parameter
     * @param resetCachedStatusExpiry (optional) if true, reset the cached subscription status expiration date to a point in the near future;
     *                                           if false, do nothing
     */
    protected function applyNewSubscriptionStatus(newStatus:Boolean, message:String=null, onDone:Function=null, resetCachedStatusExpiry:Boolean=false):void
    {
      /**/Log.out('applying new subscription status: ' + newStatus + (message!=null ? (' (' + message + ')') : ''));
      
      // remove any loading alert that may be showing
      disposeLoadingAlert();

      // get current subscription status
      var cursubsts:Boolean = GameData.instance.preferences.getBoolean(GameData.PRFNAM_SUB_IS_CURRENT);
      
      // check if subscription status has changed!
      if(newStatus!=cursubsts)
      {
        // subscription status has changed!
        /**/Log.out('subscription status has changed to: ' + (newStatus ? 'active' : 'not active'));
        GameData.instance.preferences.setBoolean(GameData.PRFNAM_SUB_IS_CURRENT,newStatus);

        // call notification method, dispatch Signal, show alert
        onSubscriptionStatusChangedInternal(newStatus);
        mSubscriptionStatusChanged.dispatch(newStatus);
        showSubscriptionStatusChangeAlert(newStatus,message);
        
        // arrange for future report of subscription activation to live host
        if(newStatus) { GameData.instance.preferences.setBoolean(GameData.PRFNAM_SUB_IS_ACTIVATION_REPORT_NEEDED,true); }
      }
      
      // reset cached subscription status expiration date if requested
      if(resetCachedStatusExpiry) {
        GameData.instance.preferences.setNumber(GameData.PRFNAM_SUB_IS_CURRENT_EXPIRY_DATE,(new Date()).getTime() + (GameData.SUB_IS_CURRENT_TTL*1000));
      }
      
      // invoke callback function
      if(onDone!=null) { onDone(newStatus); }
    }
    
    /**
     * A convenience subclass notification method that is called whenever the subscription status changes.
     */
    protected function onSubscriptionStatusChangedInternal(isSubscriptionCurrent:Boolean):void
    {
      /* override */
    }
    
    /**
     * Shows subscription status change alert with optional detail message.
     */
    protected function showSubscriptionStatusChangeAlert(isSubscriptionCurrent:Boolean, detailMessage:String=null):void
    {
      // format detail message
      var fmtdtlmsg:String = (detailMessage!=null ? ':\n(' + detailMessage + ')' : '.');
      
      // display alert
      if(isSubscriptionCurrent) {
        var actalt:Alert = new Alert(
          'Subscription Activated',
          'Thank You!  Your subscription is now active' + fmtdtlmsg
        );
        actalt.open();
        AnalyticsTracker.trackScreenView(AnalyticsTracker.SUBSCRIPTION_PURCHASE_THANK_YOU_DIALOG);
      }
      else {
        /* do not display deactivation alert for now
        var dacalt:Alert = new Alert(
          'Subscription Deactivated',
          'Your subscription has been deactivated' + fmtdtlmsg,
          new ListCollection([
            { label: "OK", triggered: function():void { dacalt.close(); } }
          ])
        );
        dacalt.open();
        */
      }
    }
    
    /**
     * @return true if the cached subscription status has expired, false if not
     */
    protected function isCachedSubscriptionStatusExpired():Boolean
    {
      /**/Log.out('checking if cached subscription status has expired...');
      
      // get cached status expiry date and current date
      var subcurexpdatnbr:Number = GameData.instance.preferences.getNumber(GameData.PRFNAM_SUB_IS_CURRENT_EXPIRY_DATE);
      var subcurexpdat:Date = isNaN(subcurexpdatnbr) ? new Date(0) /* January 1, 1970 0:00:000 GMT */ : new Date(subcurexpdatnbr);
      var curdat:Date = new Date();
      
      // compare
      /**/Log.out('comparing current date ('+ curdat + ') to cached subscription status expiration date (' + subcurexpdat + ')...');
      if(curdat.getTime()<subcurexpdat.getTime()) {
        /**/Log.out('cached subscription status has not expired (good for ' + (subcurexpdat.getTime()-curdat.getTime())/1000 + ' more seconds)');
        return false; // not expired
      }
      else {
        /**/Log.out('cached subscription status has expired');
        return true; // expired
      }
    }
    
    /**************************************************************************
     * INSTANCE METHODS - LOADING ALERT
     **************************************************************************/
    
    /**
     * Shows a loading alert.  If a loading alert is already showing, does nothing.
     */
    protected function showLoadingAlert(header:String, message:String):void
    {
      if(!mLoadingAlert) {
        mLoadingAlert = new Alert(header,message);
        mLoadingAlert.open();
      }
    }
    
    /**
     * Closes and disposes any currently visible loading alert.  If no loading alert is
     * showing, does nothing.
     */
    protected function disposeLoadingAlert():void
    {
      if(mLoadingAlert) {
        mLoadingAlert.close();
        mLoadingAlert = null;
      }
    }
    
    /**************************************************************************
     * STATIC PROPERTIES
     **************************************************************************/
    
    // purchase models
    public static const PM_FREE           :String = "FREE";
    public static const PM_SINGLE_UNLOCK  :String = "SINGLE_UNLOCK";
    public static const PM_SUBSCRIPTION   :String = "SUBSCRIPTION";

    // singleton pattern: there may be only one of these objects ever created
    private static var sInstance:PurchaseManager = null;
    
    /**************************************************************************
     * STATIC METHODS
     **************************************************************************/

    // singleton pattern
    public static function instance():PurchaseManager
    {
      if(!sInstance) {
        // use compiler flags so platform-specific classs do not get compiled / linked
        CONFIG::IOS        { sInstance = new PurchaseManagerIOS();     }
        CONFIG::ANDROID {
          if(CONFIG::FUHU) { sInstance = new PurchaseManagerFuhu();    }
          else             { sInstance = new PurchaseManagerGoogle();  }
        }
        if(!sInstance)     { sInstance = new PurchaseManager();        }
      }
      return sInstance;
    }

  }
}