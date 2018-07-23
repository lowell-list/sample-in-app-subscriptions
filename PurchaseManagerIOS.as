package com.rhino.mcfinn.swimmer.purchasing
{
  import com.greensock.events.LoaderEvent;
  import com.greensock.loading.DataLoader;
  import com.greensock.loading.LoaderMax;
  import com.milkmangames.nativeextensions.ios.StoreKit;
  import com.milkmangames.nativeextensions.ios.StoreKitProduct;
  import com.milkmangames.nativeextensions.ios.events.StoreKitErrorEvent;
  import com.milkmangames.nativeextensions.ios.events.StoreKitEvent;
  import com.rhino.liveEvents.data.EnvironmentList;
  import com.rhino.mcfinn.swimmer.data.AnalyticsTracker;
  import com.rhino.mcfinn.swimmer.data.GameData;
  import com.rhino.mcfinn.swimmer.display.starling.overlays.dialogs.Alert;
  import com.rhino.util.Log;
  
  import flash.events.TimerEvent;
  import flash.net.URLRequest;
  import flash.net.URLRequestMethod;
  import flash.net.URLVariables;
  import flash.net.navigateToURL;
  import flash.utils.Timer;
  import flash.utils.setTimeout;
  
  import feathers.data.ListCollection;

  /**
   * iOS App Store purchase manager
   */
  public class PurchaseManagerIOS extends PurchaseManager
  {
    /**************************************************************************
     * INSTANCE PROPERTIES
     **************************************************************************/
    
    private var mInitialized:Boolean;
    
    private var mLoadProductsOnDone:Function = null;                  // onDone() callback function for loadProducts()
    private var mLoadedProducts:Vector.<StoreKitProduct> = null;      // all products loaded in the most recent call to loadProducts()
    
    private var mSubscriptionCheckTimer:Timer = null;
    
    private var mMostRecentTransaction:StoreKitEvent = null;
    
    /**************************************************************************
     * INSTANCE CONSTRUCTOR
     **************************************************************************/
    
    public function PurchaseManagerIOS()
    {
      super();
      
      // init product IDs
      initProductIds();
      
      // initialize StoreKit
      mInitialized = false;
      if(!StoreKit.isSupported()) {
        Log.out('StoreKit is not supported');
        return;
      }
      StoreKit.create(true); // force use of old-style receipts TODO: use the app receipt instead!
      if(!StoreKit.storeKit.isStoreKitAvailable()) {
        Log.out("this device has purchases disabled");
        return;
      }
      mInitialized = true;
      Log.out('successfully initialized StoreKit ANE: ' + StoreKit.VERSION);
      
      // add permanent listeners
      StoreKit.storeKit.addEventListener(StoreKitEvent.PRODUCT_DETAILS_LOADED           , onProductDetailsLoaded    );
      StoreKit.storeKit.addEventListener(StoreKitErrorEvent.PRODUCT_DETAILS_FAILED      , onProductDetailsFailed    );
      StoreKit.storeKit.addEventListener(StoreKitEvent.PURCHASE_SUCCEEDED               , onPurchaseSuccess         );
      StoreKit.storeKit.addEventListener(StoreKitEvent.PURCHASE_DEFERRED                , onPurchaseDeferred        );
      StoreKit.storeKit.addEventListener(StoreKitErrorEvent.PURCHASE_FAILED             , onPurchaseFailed          );
      StoreKit.storeKit.addEventListener(StoreKitEvent.PURCHASE_CANCELLED               , onPurchaseUserCancelled   );
      StoreKit.storeKit.addEventListener(StoreKitEvent.TRANSACTIONS_RESTORED            , onTransactionsRestored    );
      StoreKit.storeKit.addEventListener(StoreKitErrorEvent.TRANSACTION_RESTORE_FAILED  , onTransactionRestoreFailed);
      StoreKit.storeKit.addEventListener(StoreKitEvent.APP_RECEIPT_REFRESHED            , onAppReceiptRefresh       );
      StoreKit.storeKit.addEventListener(StoreKitErrorEvent.APP_RECEIPT_REFRESH_FAILED  , onAppReceiptRefreshFailed );
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - GENERAL
     **************************************************************************/

    /** @inheritDoc */
    override public function restoreTransactions():void
    { 
      if(!mInitialized) { Log.out("StoreKit not initialized, could not restore transactions"); return; }
      showLoadingAlert(SwimAndPlayApp.SHORT_NAME,'Restoring Purchases...');
      StoreKit.storeKit.restoreTransactions();
    }
    
    /** @inheritDoc */
    override public function loadProducts(onDone:Function=null, refresh:Boolean=true):void
    { 
      if(!mInitialized) {
        if(onDone) { onDone(new Vector.<ProductData>()); } // empty vector
        return;
      }

      // save callback
      mLoadProductsOnDone = onDone;
      
      if(mLoadedProducts && !refresh) {
        // products are already loaded; invoke callback if supplied
        invokeLoadProductsCallback();
      }
      else {
        // load product details
        var pidlst:Vector.<String>=new Vector.<String>();
        for(var prdid:String in PRODUCTS) { pidlst.push(prdid); }
        StoreKit.storeKit.loadProductDetails(pidlst);
      }
    }
    
    /** @inheritDoc */
    override public function purchaseProduct(productData:ProductData):void
    {
      if(!mInitialized) { Log.out("StoreKit not initialized, could not purchase product!"); return; }
      showLoadingAlert(SwimAndPlayApp.SHORT_NAME,'Processing Purchase...');
      StoreKit.storeKit.purchaseProduct(productData.productId,1);
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - SUBSCRIPTION
     **************************************************************************/
    
    /** @inheritDoc */
    override public function subscriptionsSupported():Boolean {
      if(CONFIG::PURCHASE_MODEL!=PurchaseManager.PM_SUBSCRIPTION) { return false; } // purchase model must match
      return mInitialized;
    }
    
    /** @inheritDoc */
    override public function isSubscriptionCurrent(onDone:Function=null, refresh:Boolean=false):void
    {
      /**/Log.out('checking if subscription is current...');

      if(!mInitialized) { applyNewSubscriptionStatus(false,'not initialized',onDone); return; }
      
      // if refresh not required and cached subscription status has not expired, use cached subscription status
      if(!refresh && !isCachedSubscriptionStatusExpired()) {
        var cchsubsts:Boolean = GameData.instance.preferences.getBoolean(GameData.PRFNAM_SUB_IS_CURRENT);
        /**/Log.out('using cached subscription status: ' + (cchsubsts ? 'active' : 'not active'));
        applyNewSubscriptionStatus(cchsubsts,'using cached subscription status',onDone);
        return;
      }
      
      // retrieve most recent receipt
      var rptstr:String = GameData.instance.preferences.getString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA);
      /**/Log.out('most recent receipt data is [' + (rptstr==null ? rptstr : (rptstr.substr(0,20) + '...')) + ']');
      if(!rptstr) { applyNewSubscriptionStatus(false,'no receipt',onDone); return; } // no receipt found, so subscription cannot be current
      
      // send receipt to server for validation and subscription check
      /**/Log.out('requesting receipt validation from server...');
      var envnam:String = GameData.instance.preferences.getString(GameData.PRFNAM_RUN_ENVIRONMENT_NAME);
      var bseurl:String = SwimAndPlayApp.sEnvironments.getServiceBaseURL(envnam);
      var urlrqs:URLRequest = new URLRequest(bseurl + IOS_SUBSCRIPTION_WEB_SERVICE);
      var dta:URLVariables = new URLVariables();
      dta.receiptString = rptstr;
      dta.receiptStyle = 'iOS6TransactionReceipt';
      if(envnam!=EnvironmentList.DEFAULT_ENVIRONMENT_NAME && envnam!=EnvironmentList.STAGING_ENVIRONMENT_NAME) { dta.useSandbox = 'true'; }
      urlrqs.data = dta;
      urlrqs.method = URLRequestMethod.POST;
      var loader:DataLoader = new DataLoader(urlrqs, {
        name:"subscriptionCheck",
        onComplete:function(event:LoaderEvent):void
        {
          /**/Log.out('receipt validation server reply: ' + LoaderMax.getContent("subscriptionCheck"));
          
          // parse return JSON
          var rtnobj:Object = {};
          try {
            rtnobj = JSON.parse(LoaderMax.getContent("subscriptionCheck"));
          }
          catch(error:Error) {
            Log.out('could not parse subscription check reply: ' + error);
            applyNewSubscriptionStatus(false,'problem with subscription verification server',onDone);
            return;
          }
          
          // we now should have a definitive answer from the server about the subscription status
          
          // return final subscription status
          applyNewSubscriptionStatus(rtnobj.statusCode===0,null,onDone,true);
        },
        onFail:function(event:LoaderEvent):void {
          // an error occurred when trying to reach the endpoint
          Log.out('error: could not check subscription status: ' + event);
          applyNewSubscriptionStatus(false,'could not reach subscription verification server',onDone);
        }
      });
      loader.load();
    }
    
    /** @inheritDoc */
    override public function manageSubscriptions():void
    {
      if(!mInitialized) { return; }

      var alt:Alert = new Alert(
        "Manage Subscription",
        "Tap 'Manage' to open the auto-\n" +
        "renewing subscription management\n" +
        "page in the App Store.  You can also\n" +
        "reach this page by performing the\n" +
        "following steps:\n" +
        "\n" +
        "Exit the App then tap:\n" +
        "App Store > Featured > Apple ID >\n" +
        "View Apple ID > Manage App\n" +
        "Subscriptions",
        new ListCollection([
          { label: "Manage",
            triggered: function():void {
              alt.close();
              /**/Log.out('navigating to external URL for subscription management...');
              navigateToURL(new URLRequest("https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/manageSubscriptions"));
            }
          }
        ])
      );
      alt.open();
    }
    
    /** @inheritDoc */
    override public function getSubscriptionFinePrint2():String {
      return 'This subscription is a month-to-month subscription.' +
        ' It will automatically continue for as long as you choose to remain a subscriber.' +
        ' You can easily cancel your subscription anytime via the App Store.' +
        ' There are no cancellation fees.' +
        ' There are no refunds for partial months.' +
        ' After cancellation, your access to the live experience and activities will continue until the end of your last paid one-month term.';
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - SINGLE UNLOCK IAP
     **************************************************************************/
    
    /** @inheritDoc */
    override public function singleUnlockSupported():Boolean {
      if(CONFIG::PURCHASE_MODEL!=PurchaseManager.PM_SINGLE_UNLOCK) { return false; } // purchase model must match
      return mInitialized;
    }
    
    /** @inheritDoc */
    override public function isSingleUnlockProduct(productData:ProductData):Boolean {
      return (productData.productId==PID_SINGLE_UNLOCK && productData.type==ProductData.TYPE_NON_CONSUMABLE);
    }
    
    /**************************************************************************
     * INSTANCE METHODS - SUBSCRIPTION STATUS CHANGE NOTIFICATION
     **************************************************************************/
    
    override protected function onSubscriptionStatusChangedInternal(isSubscriptionCurrent:Boolean):void
    {
      // subscription status has changed:
      // send analytic events if 1) subscription status is current and 2) a non-restore purchase was just made
      if(isSubscriptionCurrent && mMostRecentTransaction) {
        var prd:StoreKitProduct = findProductById(mMostRecentTransaction.productId);
        if(prd) {
          AnalyticsTracker.trackPurchase(AnalyticsTracker.AFL_APP_STORE, mMostRecentTransaction.transactionId, prd.productId, prd.title,
            Number(prd.price), getCurrencyCodeFromLocaleId(prd.localeId));
        }
        mMostRecentTransaction = null; // no longer needed
      }
    }
    
    /**************************************************************************
     * INSTANCE METHODS - STOREKIT LISTENERS
     **************************************************************************/
    
    protected function onProductDetailsLoaded(event:StoreKitEvent):void
    {
      // DEBUG
      for each(var product:StoreKitProduct in event.validProducts) {
        Log.out("Loaded Product: "  + product.productId);
        Log.out("  Title: "         + product.title);
        Log.out("  Description: "   + product.description);
        Log.out("  String Price: "  + product.localizedPrice);
        Log.out("  Price: "         + product.price);
        Log.out("  Locale ID: "     + product.localeId);
      }
      Log.out("Loaded " + event.validProducts.length + " product(s)");
      if(event.invalidProductIds.length>0) {
        Log.out("error, invalid product ids: " + event.invalidProductIds.join(","));
      }

      // save loaded products
      mLoadedProducts = event.validProducts;
      
      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    protected function onProductDetailsFailed(event:StoreKitErrorEvent):void
    {
      Log.out("error loading products: " + event.text);
      
      // clear any products that may have already loaded
      mLoadedProducts = null;

      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    protected function onPurchaseSuccess(event:StoreKitEvent):void
    {
      Log.out("successfully purchased [" + event.productId + "]");
      
      // lookup product details
      var prddtl:Object = PRODUCTS[event.productId];
      if(prddtl==null) { Log.out("warning: unrecognized product ID: " + event.productId); return; }
      
      // process according to product type
      switch(prddtl.type as uint) {
        case ProductData.TYPE_SUBSCRIPTION: {
          
          // do nothing if purchase model not subscription!
          if(CONFIG::PURCHASE_MODEL!=PurchaseManager.PM_SUBSCRIPTION) { return; }

          // store the transaction for the most recently purchased product
          mMostRecentTransaction = event;
          
          // store this receipt as the most recent
          GameData.instance.preferences.setString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA,event.receipt);
          
          // trigger a 'subscription is current' check in the near future
          // note: do not do this immediately because upon restore it's possible for 
          //       many purchase transactions to succeed in rapid succession, so wait
          //       for the possible flurry to finish first
          restartSubscriptionCheckTimer();
          
        } break;
        case ProductData.TYPE_NON_CONSUMABLE: {
          setTimeout(function():void // delay to avoid Stage3D-in-background error 3768
          {
            disposeLoadingAlert(); // remove any loading alert that may be showing
            
            // set user preference boolean for this non-consumable
            GameData.instance.preferences.setBoolean(prddtl.userPreferenceName,true);
            
            // dispatch non-consumable purchase event
            mNonConsumablePurchased.dispatch(event.productId);
            if(event.productId==PID_SINGLE_UNLOCK) { mSingleUnlockPurchased.dispatch(); }
            
            // send analytic event
            var prd:StoreKitProduct = findProductById(event.productId);
            if(prd) {
              AnalyticsTracker.trackPurchase(AnalyticsTracker.AFL_APP_STORE, event.transactionId, prd.productId, prd.title,
                Number(prd.price), getCurrencyCodeFromLocaleId(prd.localeId));
            }

          },1000);
        } break;
        default: {
          disposeLoadingAlert(); // remove any loading alert that may be showing
          Log.out("warning: unrecognized product type: " + prddtl.type);
        } break;
      }
    }
    
    protected function onPurchaseDeferred(event:StoreKitEvent):void
    {
      Log.out("waiting for permission to buy: " + event.productId);
      disposeLoadingAlert(); // remove any loading alert that may be showing
      mMostRecentTransaction = null;
      AnalyticsTracker.trackEvent(AnalyticsTracker.PURCHASE_DEFERRED);
    }
    
    protected function onPurchaseFailed(event:StoreKitErrorEvent):void
    {
      Log.out("error purchasing product: " + event.text);
      disposeLoadingAlert(); // remove any loading alert that may be showing
      mMostRecentTransaction = null;
      AnalyticsTracker.trackEvent(AnalyticsTracker.PURCHASE_FAILED);
    }
    
    protected function onPurchaseUserCancelled(event:StoreKitEvent):void
    {
      Log.out("the user decided not to buy: " + event.productId);
      disposeLoadingAlert(); // remove any loading alert that may be showing
      mMostRecentTransaction = null;
      AnalyticsTracker.trackEvent(AnalyticsTracker.PURCHASE_CANCELED);
    }
    
    protected function onTransactionsRestored(event:StoreKitEvent):void
    {
      // a PURCHASE_SUCCEEDED was dispatched for each previous purchase, and all products should now be restored
      Log.out("restore complete!");
      disposeLoadingAlert(); // remove any loading alert that may be showing
      mMostRecentTransaction = null; // in the case of a restore, do not remember the most recently purchased product
      AnalyticsTracker.trackEvent(AnalyticsTracker.TRANSACTIONS_RESTORED);

      // show confirmation alert
      var alt:Alert = new Alert(
        SwimAndPlayApp.SHORT_NAME,
        'All previous transactions\n' +
        'have been successfully restored.'
      );
      alt.open();
    }
    
    protected function onTransactionRestoreFailed(event:StoreKitErrorEvent):void
    {
      Log.out("error restoring transactions: " + event.text);
      disposeLoadingAlert(); // remove any loading alert that may be showing
      mMostRecentTransaction = null;
      AnalyticsTracker.trackEvent(AnalyticsTracker.TRANSACTIONS_RESTORE_FAILED);
    }
    
    protected function onAppReceiptRefresh(event:StoreKitEvent):void
    {
      Log.out("refreshed the app receipt: " + event.receipt);
    }
    
    protected function onAppReceiptRefreshFailed(event:StoreKitErrorEvent):void
    {
      Log.out("could not refresh the app receipt: " + event.text);
    }
    
    /**************************************************************************
     * INSTANCE METHODS - SUBSCRIPTION CHECK TIMER
     **************************************************************************/
    
    private function restartSubscriptionCheckTimer():void
    {
      // cleanup any previous timer
      cleanupSubscriptionCheckTimer();
      
      // start new timer
      mSubscriptionCheckTimer = new Timer(1000,1);
      mSubscriptionCheckTimer.addEventListener(TimerEvent.TIMER_COMPLETE,subscriptionCheckTimerComplete);
      mSubscriptionCheckTimer.start();
    }
    
    private function subscriptionCheckTimerComplete(event:TimerEvent):void
    {
      /**/Log.out('subscription check timer triggered!');
      isSubscriptionCurrent(null,true); // force refresh
      cleanupSubscriptionCheckTimer();
    }
    
    private function cleanupSubscriptionCheckTimer():void
    {
      if(mSubscriptionCheckTimer!=null) {
        mSubscriptionCheckTimer.stop();
        mSubscriptionCheckTimer.removeEventListener(TimerEvent.TIMER_COMPLETE,subscriptionCheckTimerComplete);
        mSubscriptionCheckTimer = null;
      }
    }
    
    /**************************************************************************
     * INSTANCE METHODS - UTILITY
     **************************************************************************/
    
    private function invokeLoadProductsCallback():void
    {
      if(mLoadProductsOnDone!=null) {
        mLoadProductsOnDone(createProductDataVector());
        mLoadProductsOnDone = null;
      }
    }
    
    /**
     * Creates a vector of ProductData objects from the currently loaded StoreKitProduct objects.
     */
    private function createProductDataVector():Vector.<ProductData>
    {
      var prdvct:Vector.<ProductData> = new Vector.<ProductData>();
      if(mLoadedProducts) {
        for each(var strkitprd:StoreKitProduct in mLoadedProducts)
        {
          // make ProductData object and push it to the vector
          var prddta:ProductData = this.makeProductData(strkitprd,PRODUCTS[strkitprd.productId]);
          if(prddta!=null) { prdvct.push(prddta); }
        }
      }
      return prdvct;
    }

    private function findProductById(productId:String):StoreKitProduct
    {
      if(mLoadedProducts) {
        for each(var strkitprd:StoreKitProduct in mLoadedProducts) {
          if(strkitprd.productId == productId) { return strkitprd; }
        }
      }
      return null;
    }
    
    /**
     * Makes a single ProductData object from a StoreKitProduct and a generic product detail object.
     */
    private function makeProductData(storeKitProduct:StoreKitProduct, productDetail:Object):ProductData {
      if(storeKitProduct==null || productDetail==null) { return null; }
      return new ProductData(storeKitProduct.productId,storeKitProduct.title,storeKitProduct.description,productDetail.type,
        storeKitProduct.localizedPrice,Number(storeKitProduct.price),getCurrencyCodeFromLocaleId(storeKitProduct.localeId),productDetail.monthCount||0);
    }
    
    /**
     * Given an iOS locale identifier string, extracts the currency code and returns it.
     * 
     * @param localeId    NSLocale locale identifier string; see iOS docs
     *                    examples:
     *                      en_US@currency=USD                                      (observed coming through Milkman ANE)
     *                      en_US@calendar=gregorian;currency=USD;dummykey=blah     (crafted with XCode to see format)
     * 
     * @return currency code or "USD" if the currency code was not found
     */
    private function getCurrencyCodeFromLocaleId(localeId:String):String
    {
      var curcod:String = "USD";                          // currency code, initialized to default
      var tok:String = "currency=";                       // token to search for
      var tokidx:int = localeId.indexOf(tok);             // find index of token
      if(tokidx<0) { return curcod; }                     // token not found, return default currency code
      var stridx:int = tokidx + tok.length;               // determine currency code start index
      var endidx:int = localeId.indexOf(";",stridx);      // determine currency code end index
      if(endidx<0) { endidx = localeId.length; }
      return localeId.substring(stridx,endidx);           // return currency code
    }
    
    /**************************************************************************
     * STATIC PROPERTIES
     **************************************************************************/
    
    // URL to check subscription status
    private static const IOS_SUBSCRIPTION_WEB_SERVICE:String = 'subscriptions/iOS/checkSubscription.php';
    
    // product IDs and associated details
    private static var PRODUCTS:Object = null;
    private static var PID_SINGLE_UNLOCK:String = 'SingleUnlock';
    
    /**************************************************************************
     * STATIC METHODS
     **************************************************************************/

    private static function initProductIds():void {
      if(PRODUCTS!=null) { return; } // init only once
      PRODUCTS = {};
      if(CONFIG::PURCHASE_MODEL==PurchaseManager.PM_SUBSCRIPTION) {
        PRODUCTS[SwimAndPlayApp.APP_ID + '.LiveEvent1Month' ] = { type:ProductData.TYPE_SUBSCRIPTION, monthCount:1 };
        PRODUCTS[SwimAndPlayApp.APP_ID + '.LiveEvent3Months'] = { type:ProductData.TYPE_SUBSCRIPTION, monthCount:3 };
        PRODUCTS[SwimAndPlayApp.APP_ID + '.LiveEvent6Months'] = { type:ProductData.TYPE_SUBSCRIPTION, monthCount:6 };
      }
      if(CONFIG::PURCHASE_MODEL==PurchaseManager.PM_SINGLE_UNLOCK) {
        PRODUCTS[PID_SINGLE_UNLOCK] = { type:ProductData.TYPE_NON_CONSUMABLE, userPreferenceName:GameData.PRFNAM_SINGLE_UNLOCK_PURCHASED };
      }
    }
  }
}