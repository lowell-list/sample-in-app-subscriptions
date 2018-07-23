package com.rhino.mcfinn.swimmer.purchasing
{
  import com.greensock.events.LoaderEvent;
  import com.greensock.loading.DataLoader;
  import com.greensock.loading.LoaderMax;
  import com.rhino.ane.FuhuInAppPurchase.FuhuInAppPurchase;
  import com.rhino.ane.FuhuInAppPurchase.FuhuOrderDetail;
  import com.rhino.ane.FuhuInAppPurchase.FuhuProduct;
  import com.rhino.ane.FuhuInAppPurchase.events.FuhuErrorEvent;
  import com.rhino.ane.FuhuInAppPurchase.events.FuhuEvent;
  import com.rhino.liveEvents.data.EnvironmentList;
  import com.rhino.mcfinn.swimmer.data.AnalyticsTracker;
  import com.rhino.mcfinn.swimmer.data.GameData;
  import com.rhino.mcfinn.swimmer.display.starling.overlays.dialogs.Alert;
  import com.rhino.util.Log;
  
  import flash.net.URLRequest;
  import flash.net.URLRequestMethod;
  import flash.net.URLVariables;

  /**
   * Fuhu/Nabi purchase manager
   */
  public class PurchaseManagerFuhu extends PurchaseManager
  {
    /**************************************************************************
     * INSTANCE PROPERTIES
     **************************************************************************/
    
    private var mInitialized:Boolean;                                 // true if Fuhu IAP API has initialized and is supported
    
    private var mLoadProductsOnDone:Function = null;                  // onDone() callback function for loadProducts()
    private var mLoadedProducts:Vector.<FuhuProduct> = null;          // all products loaded in the most recent call to loadProducts()
    
    /**************************************************************************
     * INSTANCE CONSTRUCTOR
     **************************************************************************/
    
    public function PurchaseManagerFuhu()
    {
      super();
      
      // initialize ANE
      mInitialized = false;
      if(!FuhuInAppPurchase.isSupported) {
        Log.out('FuhuInAppPurchase is not supported');
        return;
      }
      FuhuInAppPurchase.instance.initialize(FUHU_PUBLIC_KEY);
      FuhuInAppPurchase.instance.enableLogging(true);
      mInitialized = true;
      Log.out('successfully initialized FuhuInAppPurchase ANE');
      
      // add permanent listeners
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.FUHU_IAP_NOT_SUPPORTED            , onFuhuIAPNotSupported           );
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.ORDER_DETAILS_LOADED              , onOrderDetailsLoaded            );
      FuhuInAppPurchase.instance.addEventListener(FuhuErrorEvent.ORDER_DETAILS_FAILED         , onOrderDetailsFailed            );
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.PRODUCT_DETAILS_LOADED            , onProductDetailsLoaded          );
      FuhuInAppPurchase.instance.addEventListener(FuhuErrorEvent.PRODUCT_DETAILS_FAILED       , onProductDetailsFailed          );
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.PURCHASE_SUCCEEDED                , onPurchaseSucceeded             );
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.PURCHASE_CANCELLED                , onPurchaseCancelled             );
      FuhuInAppPurchase.instance.addEventListener(FuhuEvent.PURCHASE_CANCELLED_ALREADY_OWNED  , onPurchaseCancelledAlreadyOwned );
      FuhuInAppPurchase.instance.addEventListener(FuhuErrorEvent.PURCHASE_FAILED              , onPurchaseFailed                );
    }
    
    /**************************************************************************
     * INSTANCE METHODS - PUBLIC - GENERAL
     **************************************************************************/
    
    /** @inheritDoc */
    override public function restoreTransactions():void {
      /**
       * For Fuhu subscriptions, restoring transactions means:
       *   1) retrieve order details for all user-owned products
       *   2) validate order details with subscription verification endpoint;
       *      if any are valid, then activate subscription!
       */
      showLoadingAlert('Subscription','Restoring Purchases...');
      FuhuInAppPurchase.instance.loadOrderDetails();
    }
    
    /** @inheritDoc */
    override public function loadProducts(onDone:Function=null, refresh:Boolean=true):void
    {
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
        FuhuInAppPurchase.instance.loadProductDetails(pidlst);
      }
    }
    
    /** @inheritDoc */
    override public function purchaseProduct(productData:ProductData):void
    {
      FuhuInAppPurchase.instance.purchaseProduct(productData.productId);
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
        applyNewSubscriptionStatus(cchsubsts,'using cached status',onDone);
        return;
      }
      
      // subscription is current if
      //   1) user has at least one cached FuhuOrderDetail object (there may be multiple) AND
      //   2) it refers to a valid/current subscription product when verified with Fuhu endpoint
      
      // retrieve most recent order details
      var orddtljsnstr:String = GameData.instance.preferences.getString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA);
      var orddtlarr:Array = null;
      try { orddtlarr = JSON.parse(orddtljsnstr) as Array; } catch(err:Error) { orddtlarr=null; }
      if(!orddtlarr) { applyNewSubscriptionStatus(false,'no valid stored order details',onDone); return; }
      if(orddtlarr.length==0) { applyNewSubscriptionStatus(false,'missing order details',onDone); return; }
      
      // convert generic order detail objects to FuhuOrderDetail objects
      var tmparr:Array = new Array();
      try {
        for each(var ordobj:Object in orddtlarr) { tmparr.push(FuhuOrderDetail.fromObject(ordobj)); }
      } catch(err:Error) {
        applyNewSubscriptionStatus(false,'invalid order details',onDone);
        return;
      }
      orddtlarr = tmparr;

      // start with first array object
      checkSubscriptionStatus(orddtlarr,0,onDone);
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
        "1) Exit this App, then open the App Zone app.\n" +
        "2) Scroll down and tap on the Account button.\n" +
        "3) Scroll down to view or edit your subscriptions."
      );
      alt.open();
    }
    
    /** @inheritDoc */
    override public function getSubscriptionFinePrint2():String {
      return 'This subscription is a month-to-month subscription.' +
        ' It will automatically continue for as long as you choose to remain a subscriber.' +
        ' You can easily cancel your subscription anytime via the App Zone app.' +
        ' There are no cancellation fees.' +
        ' There are no refunds for partial months.' +
        ' After cancellation, your access to the live experience and activities will continue until the end of your last paid one-month term.';
    }

    /**************************************************************************
     * INSTANCE METHODS - INTERNAL - SUBSCRIPTION
     **************************************************************************/
    
    /**
     * Sequentially checks the subscription status of FuhuOrderDetail objects in the given array, starting at
     * the specified index.  If the current FuhuOrderDetail object refers to a product with a current subscription,
     * applyNewSubscriptionStatus(true) is called and processing stops.  If no FuhuOrderDetail objects are found
     * that refer to a current subscription, or an error occurs, applyNewSubscriptionStatus(false) is called.
     * 
     * The subscription status of a FuhuOrderDetail object is checked via a call to the subscription verification endpoint,
     * which in turn communicates to Fuhu endpoints.
     * 
     * Note: This method calls itself recursively to process the array.
     * 
     * @param orderDetailArray  An array of FuhuOrderDetail objects
     * @param startIndex        (optional) An index into orderDetailArray, indicating where to start
     * @param onDone            (optional) Callback function of the form: onDone(isCurrent:Boolean):void
     *                          The isCurrent parameter will be true if the subscription is current; false otherwise
     */
    private function checkSubscriptionStatus(orderDetailArray:Array, startIndex:int=0, onDone:Function=null):void
    {
      // validate array index
      if(startIndex<0 || startIndex>=orderDetailArray.length) {
        applyNewSubscriptionStatus(false,'reached order detail array limit',onDone);
        return;
      }
      
      // get current order detail object
      var orddtl:FuhuOrderDetail = orderDetailArray[startIndex];
      
      // prepare URLRequest
      var envnam:String = GameData.instance.preferences.getString(GameData.PRFNAM_RUN_ENVIRONMENT_NAME);
      var bseurl:String = SwimAndPlayApp.sEnvironments.getServiceBaseURL(envnam);
      var urlrqs:URLRequest = new URLRequest(bseurl + FUHU_SUBSCRIPTION_WEB_SERVICE);
      var dta:URLVariables = new URLVariables();
      dta.productSKU = orddtl.SKU;
      dta.purchaseToken = orddtl.purchaseToken;
      if(envnam!=EnvironmentList.DEFAULT_ENVIRONMENT_NAME && envnam!=EnvironmentList.STAGING_ENVIRONMENT_NAME) { dta.useSandbox = 'true'; }
      urlrqs.data = dta;
      urlrqs.method = URLRequestMethod.POST;
      
      // request server subscription verification
      Log.out('requesting server subscription verification for SKU ' + orddtl.SKU + '...');
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
          
          // we now should have a definitive answer from the server about the subscription status for this particular order detail
          if(rtnobj.statusCode===0) {
            applyNewSubscriptionStatus(true,null,onDone,true); // subscription is valid and current - done!
            return;
          }
          
          // continue on with the next order detail
          checkSubscriptionStatus(orderDetailArray,startIndex+1,onDone); // recursive call
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
     * INSTANCE METHODS - SUBSCRIPTION STATUS CHANGE NOTIFICATION
     **************************************************************************/
    
    override protected function onSubscriptionStatusChangedInternal(isSubscriptionCurrent:Boolean):void
    {
      // note: purchase already tracked by analytics in onPurchaseSucceeded()
    }
    
    /**************************************************************************
     * INSTANCE METHODS - LISTENERS
     **************************************************************************/

    protected function onFuhuIAPNotSupported(event:FuhuErrorEvent):void
    {
      mInitialized = false; // Fuhu IAP API is not supported or available
      Log.out(event);
      
      // clear any products that may have already loaded
      mLoadedProducts = null;

      // invoke any callbacks that are set
      invokeLoadProductsCallback();
    }
    
    protected function onOrderDetailsLoaded(event:FuhuEvent):void
    {
      /*
      for each(var orderDetail:FuhuOrderDetail in event.orderDetails) {
        Log.out("Order Detail: "      + orderDetail.SKU);
        Log.out("  Package Name: "    + orderDetail.packageName);
        Log.out("  Purchase State: "  + orderDetail.purchaseState);
        Log.out("  Purchase Time: "   + orderDetail.purchaseTime);
        Log.out("  Purchase Token: "  + orderDetail.purchaseToken);
      }
      Log.out("Loaded " + event.orderDetails.length + " order details");
      */
      
      // save loaded order details Vector as JSON string
      GameData.instance.preferences.setString(GameData.PRFNAM_SUB_MOST_RECENT_PURCHASE_DATA,JSON.stringify(event.orderDetails));
      
      // immediately check subscription status, forcing a refresh
      isSubscriptionCurrent(null,true);
    }
    
    protected function onOrderDetailsFailed(event:FuhuErrorEvent):void
    {
      Log.out("error loading order details: " + event.text);
      disposeLoadingAlert(); // remove any loading alert that may be showing
    }
    
    protected function onProductDetailsLoaded(event:FuhuEvent):void
    {
      /*
      for each(var product:FuhuProduct in event.validProducts) {
        Log.out("Loaded Product: "  + product.SKU);
        Log.out("  Type: "          + product.type);
        Log.out("  Title: "         + product.title);
        Log.out("  Description: "   + product.description);
        Log.out("  Price: "         + product.price);
        Log.out("  Currency: "      + product.currency);
        Log.out("  Country: "       + product.country);
        Log.out("  Coins: "         + product.coins);
        Log.out("  URL: "           + product.url);
      }
      Log.out("Loaded " + event.validProducts.length + " products");
      */

      // save loaded products
      mLoadedProducts = event.validProducts;
      
      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    protected function onProductDetailsFailed(event:FuhuErrorEvent):void
    {
      Log.out("error loading products: " + event.text);
      
      // clear any products that may have already loaded
      mLoadedProducts = null;
      
      // invoke callback if there is one
      invokeLoadProductsCallback();
    }
    
    protected function onPurchaseSucceeded(event:FuhuEvent):void
    {
      var fhuorddtl:FuhuOrderDetail = event.orderDetails[0]; // there will be only one FuhuOrderDetail
      Log.out("purchase succeeded for SKU " + fhuorddtl.SKU);
      
      // analytics: track purchase
      var fhuprd:FuhuProduct = findProductBySKU(fhuorddtl.SKU);
      if(fhuprd) {
        AnalyticsTracker.trackPurchase(AnalyticsTracker.AFL_FUHU_STORE, fhuorddtl.purchaseToken, fhuorddtl.SKU, fhuprd.title,
          fhuprd.price, fhuprd.currency);
      }
      
      // trigger a restore operation
      showLoadingAlert('Subscription','Loading...'); // override default message
      restoreTransactions();
    }

    protected function onPurchaseCancelled(event:FuhuEvent):void
    {
      Log.out("purchase cancelled: " + event);
    }
    
    protected function onPurchaseCancelledAlreadyOwned(event:FuhuEvent):void
    {
      Log.out("purchase cancelled, already owned: " + event);
      
      // trigger a restore operation
      showLoadingAlert('Subscription','Refreshing...'); // override default message
      restoreTransactions();
    }
    
    protected function onPurchaseFailed(event:FuhuErrorEvent):void
    {
      Log.out("purchase failed: " + event);
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
        for each(var fhuprd:FuhuProduct in mLoadedProducts)
        {
          // get associated product details
          var prddtl:Object = PRODUCTS[fhuprd.SKU];
          if(!prddtl) { continue; }
          
          // create new ProductData
          var lclprc:String = (fhuprd.currency=='USD') ? '$'+fhuprd.price : String(fhuprd.price);
          prdvct.push(new ProductData(fhuprd.SKU,fhuprd.title,fhuprd.description,ProductData.TYPE_SUBSCRIPTION,
            lclprc,fhuprd.price,fhuprd.currency,prddtl.monthCount));
        }
      }
      return prdvct;
    }
    
    private function findProductBySKU(sku:String):FuhuProduct
    {
      if(mLoadedProducts) {
        for each(var fhuprd:FuhuProduct in mLoadedProducts) {
          if(fhuprd.SKU == sku) { return fhuprd; }
        }
      }
      return null;
    }
    
    /**************************************************************************
     * STATIC PROPERTIES
     **************************************************************************/
    
    // product IDs and associated details
    private static const PRODUCTS:Object = {
      'com.captainmcfinn.SwimAndPlay.LiveEvent1Month'   : { monthCount: 1  },
      'com.captainmcfinn.SwimAndPlay.LiveEvent1Year'    : { monthCount: 12 }
    };
    
    // URL to check subscription status
    private static const FUHU_SUBSCRIPTION_WEB_SERVICE:String = 'subscriptions/Fuhu/checkFuhuSubscription.php';
    
    // Fuhu public key for signature verification
    private static const FUHU_PUBLIC_KEY:String = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDB4Aq0yuRRmonKkAq2laZDWXVlD53kyPAyvFx3QJDYBKwhM53OvdwjpHa0/h2XDUwz5KgW6Q5U7FejUWBq8xgnD+g5EccZjv4cZ7kdIMeN189o4SNhpOOM4JLkx9G3H83xjZztZdpNKLyfFkeuPLO1bC3j5keCyx4MGvrqqKCI0QIDAQAB";
    
    /**************************************************************************
     * STATIC METHODS
     **************************************************************************/

  }
}