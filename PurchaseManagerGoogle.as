package com.rhino.mcfinn.swimmer.purchasing
{
  import com.greensock.events.LoaderEvent;
  import com.greensock.loading.DataLoader;
  import com.greensock.loading.LoaderMax;
  import com.milkmangames.nativeextensions.android.AndroidIAB;
  import com.milkmangames.nativeextensions.android.AndroidItemDetails;
  import com.milkmangames.nativeextensions.android.AndroidPurchase;
  import com.milkmangames.nativeextensions.android.events.AndroidBillingErrorEvent;
  import com.milkmangames.nativeextensions.android.events.AndroidBillingErrorID;
  import com.milkmangames.nativeextensions.android.events.AndroidBillingEvent;
  import com.rhino.mcfinn.swimmer.data.AnalyticsTracker;
  import com.rhino.mcfinn.swimmer.data.GameData;
  import com.rhino.mcfinn.swimmer.display.starling.overlays.dialogs.Alert;
  import com.rhino.util.Log;
  
  import flash.net.URLRequest;
  import flash.net.URLRequestMethod;
  import flash.net.URLVariables;

  /**
   * Google Play purchase manager
   */
  public class PurchaseManagerGoogle extends PurchaseManager
  {
    /**************************************************************************
     * INSTANCE PROPERTIES
     **************************************************************************/
    
    private var mReceivedServiceReply:Boolean;                        // true if we have received a reply after startBillingService()
    private var mInitialized:Boolean;                                 // true if ANE has initialized and billing service is ready
    
    private var mLoadProductsOnDone:Function = null;                  // onDone() callback function for loadProducts()
    private var mLoadedProducts:Vector.<AndroidItemDetails> = null;   // all products loaded in the most recent call to loadProducts()

    /**************************************************************************
     * INSTANCE CONSTRUCTOR
     **************************************************************************/
    
    public function PurchaseManagerGoogle()
    {
      super();
      
      // init
      mReceivedServiceReply = false;
      mInitialized = false;

      // initialize AndroidIAB
      if(!AndroidIAB.isSupported()) {
        Log.out('AndroidIAB is not supported');
        return;
      }
      AndroidIAB.create();

      // add permanent listeners
      AndroidIAB.androidIAB.addEventListener(AndroidBillingEvent.SERVICE_READY,               onServiceReady          );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingEvent.SERVICE_NOT_SUPPORTED,       onServiceUnsupported    );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingEvent.INVENTORY_LOADED,            onInventoryLoadSuccess  );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingErrorEvent.LOAD_INVENTORY_FAILED,  onInventoryLoadFailed   );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingEvent.ITEM_DETAILS_LOADED,         onItemDetailsLoadSuccess);
      AndroidIAB.androidIAB.addEventListener(AndroidBillingErrorEvent.ITEM_DETAILS_FAILED,    onItemDetailsLoadFailed );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingEvent.PURCHASE_SUCCEEDED,          onPurchaseSuccess       );
      AndroidIAB.androidIAB.addEventListener(AndroidBillingErrorEvent.PURCHASE_FAILED,        onPurchaseFailed        );

      // start the service
      AndroidIAB.androidIAB.startBillingService(APP_LICENSE_KEY);
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - GENERAL
     **************************************************************************/
    
    /** @inheritDoc */
    override public function restoreTransactions():void {
      /**
       * For Google subscriptions, restoring transactions means:
       *   1) retrieve all purchase objects for the current user
       *   2) validate purchase objects with subscription verification endpoint;
       *      if any are valid, then activate subscription!
       */
      if(!mInitialized) { Log.out('not initialized: could not restore transactions'); return; }
      showLoadingAlert('Subscription','Restoring Purchases...');
      AndroidIAB.androidIAB.loadPlayerInventory();
    }
    
    /** @inheritDoc */
    override public function loadProducts(onDone:Function=null, refresh:Boolean=true):void
    {
      // save callback
      mLoadProductsOnDone = onDone;
      
      if(!mInitialized) {
        Log.out('not initialized: could not load products');
        invokeLoadProductsCallback();
      }
      else if(mLoadedProducts && !refresh) {
        // products are already loaded; invoke callback if supplied
        invokeLoadProductsCallback();
      }
      else {
        // load product details
        var pidlst:Vector.<String>=new Vector.<String>();
        for(var prdid:String in PRODUCTS) { pidlst.push(prdid); }
        AndroidIAB.androidIAB.loadItemDetails(pidlst);
      }
    }
    
    /** @inheritDoc */
    override public function purchaseProduct(productData:ProductData):void
    {
      if(!mInitialized) { Log.out('not initialized: could not purchase subscription'); return; }
      AndroidIAB.androidIAB.purchaseSubscriptionItem(productData.productId);
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - SUBSCRIPTION
     **************************************************************************/
    
    /** @inheritDoc */
    override public function subscriptionsSupported():Boolean {
      if(CONFIG::PURCHASE_MODEL!=PurchaseManager.PM_SUBSCRIPTION) { return false; } // purchase model must match
      if(!mReceivedServiceReply) { return true;         } // no service reply yet, so assume YES, subscriptions are supported
      else                       { return mInitialized; } // reply with definitive answer
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
        applyNewSubscriptionStatus(cchsubsts,'using cached status',onDone);
        return;
      }
      
      // subscription is current if
      //   1) user has at least one cached AndroidPurchase object (there may be multiple) AND
      //   2) it refers to a valid/current subscription product when verified with Google endpoint

      // retrieve most recent purchase objects
      var pchjsnstr:String = GameData.instance.preferences.getString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA);
      var pchobjarr:Array = null;
      try { pchobjarr = JSON.parse(pchjsnstr) as Array; } catch(err:Error) { pchobjarr=null; }
      if(!pchobjarr) { applyNewSubscriptionStatus(false,'no valid stored purchase data',onDone); return; }
      if(pchobjarr.length==0) { applyNewSubscriptionStatus(false,'missing purchase data',onDone); return; }
      
      // convert generic purchase objects to AndroidPurchase objects
      var tmparr:Array = new Array();
      try {
        for each(var pchobj:Object in pchobjarr) {
          var pch:AndroidPurchase = new AndroidPurchase();
          for(var prp:String in pchobj) { pch[prp] = pchobj[prp]; } // copy all properties
          tmparr.push(pch);
        }
      } catch(err:Error) {
        applyNewSubscriptionStatus(false,'invalid purchase object',onDone);
        return;
      }
      pchobjarr = tmparr;
      
      // process array starting with the first array object
      checkSubscriptionStatus(pchobjarr,0,onDone);
    }

    /** @inheritDoc */
    override public function manageSubscriptions():void
    {
      if(!mInitialized) { return; }
      
      var alt:Alert = new Alert(
        "Manage Subscription",
        "To manage your subscription,\n" +
        "please do the following:\n" +
        "\n" +
        "1) Visit Google Wallet at\n" +
        "https://wallet.google.com\n" +
        "2) Along the left side of your screen,\n" +
        "select More > Subscriptions\n"
      );
      alt.open();
      // note: directions from https://support.google.com/googleplay/answer/2476088?hl=en
    }
    
    /** @inheritDoc */
    override public function getSubscriptionFinePrint2():String {
      return 'This subscription is a month-to-month subscription.' +
        ' It will automatically continue for as long as you choose to remain a subscriber.' +
        ' You can easily cancel your subscription anytime via the Google Wallet app.' +
        ' There are no cancellation fees.' +
        ' There are no refunds for partial months.' +
        ' After cancellation, your access to the live experience and activities will continue until the end of your last paid one-month term.';
    }
    
    /**************************************************************************
     * INSTANCE METHODS - INTERNAL - SUBSCRIPTION
     **************************************************************************/
    
    /**
     * Sequentially checks the subscription status of AndroidPurchase objects in the given array, starting at
     * the specified index.  If the current AndroidPurchase object refers to a product with a current subscription,
     * applyNewSubscriptionStatus(true) is called and processing stops.  If no AndroidPurchase objects are found
     * that refer to a current subscription, or an error occurs, applyNewSubscriptionStatus(false) is called.
     * 
     * The subscription status of an AndroidPurchase object is checked via a call to the subscription verification endpoint,
     * which in turn communicates to Google endpoints.
     * 
     * Note: This method calls itself recursively to process the array.
     * 
     * @param purchaseObjectArray   An array of AndroidPurchase objects
     * @param startIndex            (optional) An index into purchaseObjectArray, indicating where to start
     * @param onDone                (optional) Callback function of the form: onDone(isCurrent:Boolean):void
     *                              The isCurrent parameter will be true if the subscription is current; false otherwise
     */
    private function checkSubscriptionStatus(purchaseObjectArray:Array, startIndex:int=0, onDone:Function=null):void
    {
      // validate array index
      if(startIndex<0 || startIndex>=purchaseObjectArray.length) {
        applyNewSubscriptionStatus(false,'reached purchase object array limit',onDone);
        return;
      }
      
      // get current purchase object
      var pch:AndroidPurchase = purchaseObjectArray[startIndex];
      /**/Log.out("processing AndroidPurchase object " + JSON.stringify(pch));
      
      // prepare URLRequest
      var envnam:String = GameData.instance.preferences.getString(GameData.PRFNAM_RUN_ENVIRONMENT_NAME);
      var bseurl:String = SwimAndPlayApp.sEnvironments.getServiceBaseURL(envnam);
      var urlrqs:URLRequest = new URLRequest(bseurl + GOOGLE_SUBSCRIPTION_WEB_SERVICE);
      var dta:URLVariables = new URLVariables();
      dta.productId = pch.itemId;
      dta.purchaseToken = pch.purchaseToken;
      urlrqs.data = dta;
      urlrqs.method = URLRequestMethod.POST;
      
      // request server subscription verification
      Log.out('requesting server subscription verification for purchased item ' + pch.itemId + '...');
      const LDRNAM:String = "subscriptionCheckLoader";
      var loader:DataLoader = new DataLoader(urlrqs, {
        name:LDRNAM,
        onComplete:function(event:LoaderEvent):void
        {
          Log.out('subscription verification server reply: ' + LoaderMax.getContent(LDRNAM));
          
          // parse return JSON
          var rtnobj:Object = {};
          try {
            rtnobj = JSON.parse(LoaderMax.getContent(LDRNAM));
          }
          catch(error:Error) {
            Log.out('could not parse subscription check reply: ' + error);
            applyNewSubscriptionStatus(false,'problem with subscription verification server',onDone);
            return;
          }
          
          // we now should have a definitive answer from the server about the subscription status for this particular item
          if(rtnobj.statusCode===0) {
            applyNewSubscriptionStatus(true,null,onDone,true); // subscription is valid and current - done!
            return;
          }
          
          // continue on to the next array item
          checkSubscriptionStatus(purchaseObjectArray,startIndex+1,onDone); // recursive call
        },
        onFail:function(event:LoaderEvent):void {
          // an error occurred when trying to reach the endpoint
          Log.out('error: could not check subscription status: ' + event);
          applyNewSubscriptionStatus(false,'could not reach subscription verification server',onDone);
        }
      });
      loader.load();
    }
    
    /**************************************************************************
     * INSTANCE METHODS - LISTENERS
     **************************************************************************/

    private function onServiceReady(event:AndroidBillingEvent):void
    {
      mReceivedServiceReply = true;
      
      // check if subscriptions are supported
      if(!AndroidIAB.androidIAB.areSubscriptionsSupported()) {
        mInitialized = false;
        Log.out('subscriptions are not supported on this device');
        return;
      }
      
      // successfully initialized
      mInitialized = true;
      Log.out('successfully initialized AndroidIAB ANE: ' + AndroidIAB.VERSION);
    }
    
    private function onServiceUnsupported(event:AndroidBillingEvent):void
    {
      mReceivedServiceReply = true;
      mInitialized = false;
      Log.out("service is unsupported");
    }
    
    private function onInventoryLoadSuccess(event:AndroidBillingEvent):void
    {
      /**/
      for each(var pch:AndroidPurchase in event.purchases) {
        Log.out("Purchase Detail: "     + pch.itemId);
        Log.out("  Developer Payload: " + pch.developerPayload);
        Log.out("  Item Type: "         + pch.itemType);
        Log.out("  JSON Data: "         + pch.jsonData);
        Log.out("  Order Id: "          + pch.orderId);
        Log.out("  Signature: "         + pch.signature);
        Log.out("  Purchase Time: "     + pch.purchaseTime);
        Log.out("  Purchase Token: "    + pch.purchaseToken);
      }
      Log.out("Loaded " + event.purchases.length + " purchase details");
      /**/

      // save loaded purchase details Vector as JSON string
      GameData.instance.preferences.setString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA,JSON.stringify(event.purchases));
      
      // immediately check subscription status, forcing a refresh
      isSubscriptionCurrent(null,true);
    }
    
    private function onInventoryLoadFailed(event:AndroidBillingErrorEvent):void
    {
      Log.out("error loading inventory: " + event.text);
      disposeLoadingAlert(); // remove any loading alert that may be showing
    }
    
    private function onItemDetailsLoadSuccess(event:AndroidBillingEvent):void
    {
      /**/
      for each(var itmdtl:AndroidItemDetails in event.itemDetails)
      {
        Log.out("Loaded Item: "     + itmdtl.itemId);
        Log.out("  Type: "          + itmdtl.itemType);
        Log.out("  Title: "         + itmdtl.title);
        Log.out("  Description: "   + itmdtl.description);
        Log.out("  Price: "         + itmdtl.price);
        Log.out("  Price Micros: "  + itmdtl.priceAmountMicros);
        Log.out("  Currency Code: " + itmdtl.priceCurrencyCode);
      }
      Log.out("Loaded " + event.itemDetails.length + " item details");
      /**/
      
      // save loaded products
      mLoadedProducts = event.itemDetails;
      
      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    private function onItemDetailsLoadFailed(event:AndroidBillingErrorEvent):void
    {
      Log.out("error loading item details: " + event.text);
      
      // clear any products that may have already loaded
      mLoadedProducts = null;
      
      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    private function onPurchaseSuccess(event:AndroidBillingEvent):void
    {
      var pch:AndroidPurchase = event.purchases[0];
      Log.out("purchase succeeded for item " + pch.itemId);
      /**/
      Log.out("Purchase Detail: "     + pch.itemId);
      Log.out("  Developer Payload: " + pch.developerPayload);
      Log.out("  Item Type: "         + pch.itemType);
      Log.out("  JSON Data: "         + pch.jsonData);
      Log.out("  Order Id: "          + pch.orderId);
      Log.out("  Signature: "         + pch.signature);
      Log.out("  Purchase Time: "     + pch.purchaseTime);
      Log.out("  Purchase Token: "    + pch.purchaseToken);
      /**/

      // analytics: track purchase
      var itmdtl:AndroidItemDetails = findProductById(pch.itemId);
      if(itmdtl) {
        AnalyticsTracker.trackPurchase(AnalyticsTracker.AFL_GOOGLE_PLAY, pch.orderId, pch.itemId, itmdtl.title,
          itmdtl.priceAmountMicros/1000000, itmdtl.priceCurrencyCode);
      }
      
      // trigger a restore operation
      showLoadingAlert('Subscription','Loading...'); // override default message
      restoreTransactions();
    }
    
    private function onPurchaseFailed(event:AndroidBillingErrorEvent):void
    {
      Log.out("purchase failed for item " + event.itemId + " : " + event.text);
      
      // if failure was because item is already owned, trigger a restore operation
      if(event.errorID == AndroidBillingErrorID.ITEM_ALREADY_OWNED) {
        showLoadingAlert('Subscription','Refreshing...'); // override default message
        restoreTransactions();
      }
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PRODUCT UTILITY
     **************************************************************************/
    
    private function invokeLoadProductsCallback():void
    {
      if(mLoadProductsOnDone!=null) {
        mLoadProductsOnDone(createProductDataVector());
        mLoadProductsOnDone = null;
      }
    }
    
    private function createProductDataVector():Vector.<ProductData>
    {
      var prdvct:Vector.<ProductData> = new Vector.<ProductData>();
      if(mLoadedProducts) {
        for each(var itmdtl:AndroidItemDetails in mLoadedProducts)
        {
          // get associated product details
          var prddtl:Object = PRODUCTS[itmdtl.itemId];
          if(!prddtl) { continue; }
          
          // create new ProductData
          prdvct.push(new ProductData(itmdtl.itemId,itmdtl.title,itmdtl.description,ProductData.TYPE_SUBSCRIPTION,
            itmdtl.price,itmdtl.priceAmountMicros/1000000,itmdtl.priceCurrencyCode,prddtl.monthCount));
        }
      }
      return prdvct;
    }
    
    private function findProductById(productId:String):AndroidItemDetails
    {
      if(mLoadedProducts) {
        for each(var itmdtl:AndroidItemDetails in mLoadedProducts) {
          if(itmdtl.itemId == productId) { return itmdtl; }
        }
      }
      return null;
    }

    /**************************************************************************
     * STATIC PROPERTIES
     **************************************************************************/
    
    // product IDs and associated details
    private static const PRODUCTS:Object = {
      'com.captainmcfinn.swimandplay.liveevent1month'   : { monthCount: 1  },
      'com.captainmcfinn.swimandplay.liveevent1year'    : { monthCount: 12 }
    };
    
    // URL to check subscription status
    private static const GOOGLE_SUBSCRIPTION_WEB_SERVICE:String = 'subscriptions/Google/checkGoogleSubscription.php';
    
    // Google Play app license key - Base64 RSA public key
    private static const APP_LICENSE_KEY:String = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3Wa1jicTKpx/Dbinl4RUPPnxEyZHy9Dn57aqoJymLXH/I9gzlApKawqceAd2RVYc+/S0MkUXeMvd4xO3VYxNesYJ5cP9aGyDktk7jSAZnYr/GdoTd/liSkQvDTALbMIjUFehjGeYOS0WbzMlIdr9FQi5aPRHZMXhAeGzn/k3wVjERKIx9BOz5vMbMxKLPatQHlNfRIK2orKoNIjFwPPVns7zb9RBVcBsOp57r4s9eH3V7X259itnVGQP9ZliTDnSIOHwAShUXpFSR7Rsu/+ygpS/oq1CDbVIlO8NhiYyeRXTZ4wopp0dOazrf/gK2pPw9fDfxllUHCAmFRwDVlWMawIDAQAB";

    /**************************************************************************
     * STATIC METHODS
     **************************************************************************/

  }
}