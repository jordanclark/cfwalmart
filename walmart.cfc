component {
	cfprocessingdirective( preserveCase=true );

	walmart function init( required string apiClientID, required string apiClientSecret, string apiUrl= "https://marketplace.walmartapis.com/v3", string userAgent= "CFML API Agent 0.1", numeric httpTimeOut= 60 ) {
		this.apiClientID= arguments.apiClientID;
		this.apiClientSecret= arguments.apiClientSecret;
		this.apiAccessToken= "";
		this.apiTokenExpires= now();
		this.apiUrl= arguments.apiUrl;
		this.userAgent= arguments.userAgent;
		this.httpTimeOut= arguments.httpTimeOut;
		this.lastRequest= 0;
		if ( structKeyExists( server, "walmartAuth" ) ) {
			this.apiAccessToken= server.walmartAuth.token;
			this.apiTokenExpires= server.walmartAuth.expires;
		}
		this.offSet = getTimeZoneInfo().utcTotalOffset;
		this.orderStatusOptions= [
			'All'
		,	'Created'
		,	'Acknowledged'
		,	'Shipped'
		,	'Cancelled'
		];
		return this;
	}

	function debugLog( required input ) {
		if ( structKeyExists( request, "log" ) && isCustomFunction( request.log ) ) {
			if ( isSimpleValue( arguments.input ) ) {
				request.log( "walmart: " & arguments.input );
			} else {
				request.log( "walmart: (complex type)" );
				request.log( arguments.input );
			}
		} else {
			cftrace( text=( isSimpleValue( arguments.input ) ? arguments.input : "" ), var=arguments.input, category="walmart", type="information" );
		}
		return;
	}

	struct function apiRequest( required string api ) {
		var wait= 0;
		var http= {};
		var item= "";
		var out= {
			args= arguments
		,	success= false
		,	error= ""
		,	status= ""
		,	statusCode= 0
		,	response= ""
		,	verb= listFirst( arguments.api, " " )
		,	requestUrl= this.apiUrl
		,	data= {}
		,	correlationID = getTickCount()
		,	accept= "application/json"
		};
		out.requestUrl &= listRest( out.args.api, " " );
		structDelete( out.args, "api" );
		// replace {var} in url 
		for ( item in out.args ) {
			// strip NULL values 
			if ( isNull( out.args[ item ] ) ) {
				structDelete( out.args, item );
			} else if ( isSimpleValue( arguments[ item ] ) && arguments[ item ] == "null" ) {
				arguments[ item ]= javaCast( "null", 0 );
			} else if ( findNoCase( "{#item#}", out.requestUrl ) ) {
				out.requestUrl= replaceNoCase( out.requestUrl, "{#item#}", out.args[ item ], "all" );
				structDelete( out.args, item );
			}
		}
		if ( out.verb == "GET" ) {
			out.requestUrl &= this.structToQueryString( out.args, out.requestUrl, false );
		} else if ( structKeyExists( out.args, "file" ) ) {
			out.body= out.args.file;
			out.accept = "application/xml";
			structDelete( out.args, "file" );
		} else if ( structKeyExists( out.args, "json" ) ) {
			out.body= serializeJSON( out.args.json );
			structDelete( out.args, "json" );
		}
		this.debugLog( "API: #uCase( out.verb )#: #out.requestUrl#" );
		if ( structKeyExists( out, "body" ) ) {
			this.debugLog( out.body );
		}
		// this.debugLog( out );
		cftimer( type="debug", label="walmart request" ) {
			if ( !len( this.apiAccessToken ) || dateDiff( "s", now(), this.apiTokenExpires ) < 10 ) {
				cfhttp( charset="UTF-8", throwOnError=false, userAgent=this.userAgent, url="https://marketplace.walmartapis.com/v3/token", timeOut=this.httpTimeOut, result="out.auth", method="POST" ) {
					cfhttpparam( name="Authorization", type="header", value="Basic #ToBase64('#this.apiClientID#:#this.apiClientSecret#')#" );
					cfhttpparam( name="Content-Type", type="header", value="application/x-www-form-urlencoded" );
					cfhttpparam( name="Accept", type="header", value="application/json" );
					cfhttpparam( name="WM_SVC.NAME", type="header", value="Walmart Marketplace" );
					cfhttpparam( name="WM_SVC.VERSION", type="header", value="1.0.0" );
					cfhttpparam( name="WM_QOS.CORRELATION_ID", type="header", value=out.correlationID );
					cfhttpparam( type="body", value="grant_type=client_credentials" );
				}
				this.debugLog( "Authenticate" );
				this.debugLog( out.auth );
				if ( left( out.auth.status_code, 1 ) == 2 ) {
					// 200 OK
					var authToken= deserializeJSON( out.auth.fileContent );
					this.apiAccessToken = authToken.access_token;
					this.apiTokenExpires = dateAdd( "S", authToken.expires_in, now() );
					server.walmartAuth = {
						token = this.apiAccessToken
					,	expires = this.apiTokenExpires
					};
				}
			}
			cfhttp( result="http", method=out.verb, url=out.requestUrl, charset="UTF-8", throwOnError=false, userAgent=this.userAgent, timeOut=this.httpTimeOut ) {
				cfhttpparam( name="Authorization", type="header", value="Basic #ToBase64('#this.apiClientID#:#this.apiClientSecret#')#" );
				if ( len( this.apiAccessToken ) ) {
					cfhttpparam( name="WM_SEC.ACCESS_TOKEN", type="header", value=this.apiAccessToken );
				}
				if ( structKeyExists( out, "file" ) ) {
					cfhttpparam( name="Content-Type", type="header", value="multipart/formdata" );
				} else {
					cfhttpparam( name="Content-Type", type="header", value="application/x-www-form-urlencoded" );
				}
				cfhttpparam( name="Accept", type="header", value=out.accept );
				cfhttpparam( name="WM_SVC.NAME", type="header", value="Walmart Marketplace" );
				cfhttpparam( name="WM_SVC.VERSION", type="header", value="1.0.0" );
				cfhttpparam( name="WM_QOS.CORRELATION_ID", type="header", value=out.correlationID );
				if ( structKeyExists( out, "file" ) ) {
					cfhttpparam( type="body", value=out.file );
				} else if ( structKeyExists( out, "body" ) ) {
					cfhttpparam( type="body", value=out.body );
				}
			}
		}
		out.response= toString( http.fileContent );
		out.statusCode = http.responseHeader.Status_Code ?: 500;
		this.debugLog( out.statusCode );
		if ( left( out.statusCode, 1 ) == 4 || left( out.statusCode, 1 ) == 5 ) {
			out.success= false;
			out.error= "status code error: #out.statusCode#";
		} else if ( out.response == "Connection Timeout" || out.response == "Connection Failure" ) {
			out.error= out.response;
		} else if ( left( out.statusCode, 1 ) == 2 ) {
			out.success= true;
		}
		// parse response 
		try {
			if ( out.accept == "application/json" ) {
				out.data= deserializeJSON( out.response );
			} else if ( out.accept == "application/xml" ) {
				out.data= xmlParse( out.response );
			}
			if ( isStruct( out.data ) && structKeyExists( out.data, "errors" ) ) {
				out.success= false;
				out.error= out.data.errors.error[1].description;
			} else if ( isStruct( out.data ) && structKeyExists( out.data, "status" ) && out.data.status == 400 ) {
				out.success= false;
				out.error= out.data.detail;
			}
		} catch (any cfcatch) {
			out.error= "Response Error: " & cfcatch.message;
		}
		if ( len( out.error ) ) {
			out.success= false;
		}
		return out;
	}

	// ---------------------------------------------------------------------------- 
	// ITEMS 
	// ---------------------------------------------------------------------------- 

	struct function token( string grant_type= "client_credentials" ) {
		var out= this.apiRequest( api= "POST /token", argumentCollection= arguments );
		if ( out.success ) {
			this.apiAccessToken = out.data.access_token;
			this.apiTokenExpires = now().dateAdd( "S", out.data.expires_in );
		}
		return out;
	}

	struct function getInventory( required string sku ) {
		return this.apiRequest( api= "GET /inventory", argumentCollection= arguments );
	}

	struct function getLagTime( required string sku ) {
		return this.apiRequest( api= "GET /lagtime", argumentCollection= arguments );
	}

	struct function updateLagTime( required string sku, required string lagtime ) {
		var body =
			'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
			<LagTimeFeed xmlns="http://walmart.com/">
			<LagTimeHeader><version>1.0</version></LagTimeHeader>
			<lagTime><sku>#arguments.sku#</sku><fulfillmentLagTime>#arguments.lagtime#</fulfillmentLagTime></lagTime>
			</LagTimeFeed>';
		return this.apiRequest( api= "POST /feeds/?feedType=lagtime", body= body );
	}

	struct function getReleasedOrders( required string createdStartDate, string createdEndDate, numeric limit= 10 ) {
		if ( structKeyExists( arguments, "createStartDate" ) && len( arguments.createStartDate ) ) {
			arguments.createStartDate= zDateFormat( arguments.createStartDate );
		}
		if ( structKeyExists( arguments, "createdEndDate" ) && len( arguments.createdEndDate ) ) {
			arguments.createdEndDate= zDateFormat( arguments.createdEndDate );
		}
		return this.apiRequest( api= "GET /orders/released", argumentCollection= arguments );
	}

	struct function getOrders( string sku, string customerOrderId, string purchaseOrderId, string status, string createdStartDate, string createdEndDate, string fromExpectedShipDate, string toExpectedShipDate, string nextCursor, numeric limit= 10, numeric start= 0 ) {
		if ( structKeyExists( arguments, "createStartDate" ) && len( arguments.createStartDate ) ) {
			arguments.createStartDate= zDateFormat( arguments.createStartDate );
		}
		if ( structKeyExists( arguments, "createdEndDate" ) && len( arguments.createdEndDate ) ) {
			arguments.createdEndDate= zDateFormat( arguments.createdEndDate );
		}
		if ( structKeyExists( arguments, "fromExpectedShipDate" ) && len( arguments.fromExpectedShipDate ) ) {
			arguments.fromExpectedShipDate= zDateFormat( arguments.fromExpectedShipDate );
		}
		if ( structKeyExists( arguments, "toExpectedShipDate" ) && len( arguments.toExpectedShipDate ) ) {
			arguments.toExpectedShipDate= zDateFormat( arguments.toExpectedShipDate );
		}
		if ( structKeyExists( arguments, "start" ) && arguments.start > 0 ) {
			arguments.poIndex= arguments.start;
			structDelete( arguments, "start" );
		}
		if ( structKeyExists( arguments, "status" ) && arguments.status == "All" ) {
			structDelete( arguments, "status" );
		}
		var out= this.apiRequest( api= "GET /orders", argumentCollection= arguments );
		if ( out.success ) {
			out.data = {
				orders= out.data.list.elements.order
			,	meta= out.data.list.meta
			};
			for ( o in out.data.orders ) {
				o.items = o.orderLines.orderLine;
				o.total = 0;
				structDelete( o, "orderLines" );
				o.orderDate = this.epochParse( o.orderDate );
				o.shippingInfo.estimatedDeliveryDate = this.epochParse( o.shippingInfo.estimatedDeliveryDate );
				o.shippingInfo.estimatedShipDate = this.epochParse( o.shippingInfo.estimatedShipDate );
				for ( i in o.items ) {
					i.qty = i.orderLineQuantity.amount;
					i.statusDate = this.epochParse( i.statusDate );
					i.fulfillment.pickUpDateTime = this.epochParse( i.fulfillment.pickUpDateTime );
					i.status = i.orderLineStatuses.orderLineStatus[1];
					structDelete( i, "orderLineStatuses" );
					i.tax = i.charges.charge[1].tax ?: 0;
					i.amount = i.charges.charge[1].chargeAmount.amount;
					// structDelete( i, "charges" );
					o.total += ( i.qty * i.amount ) + i.tax;
				}
			}
		} else if ( findNoCase( "Orders !found for given search parameters", out.error ) ) {
			out.success = true;
			out.error = "";
			out.data = {
				orders= []
			,	meta= {}
			};
		}
		return out;
	}

	struct function getOrder( required string id ) {
		return this.apiRequest( api= "GET /orders/{id}", argumentCollection= arguments );
	}

	struct function shipFullOrder( required string id, required string carrier, required string trackingNumber, string methodCode= "Standard", string date= now() ) {
		var order= this.getOrder( arguments.id );
		var lines= [];
		for ( l in order.data.order.orderLines.orderLine ) {
			if ( l.orderLineStatuses.orderLineStatus[1].status == "Acknowledged" ) {
				arrayAppend( lines, {
					"lineNumber": l.lineNumber,
					"orderLineStatuses": {
						"orderLineStatus": [ {
							"status": "Shipped",
							"statusQuantity": l.orderLineQuantity,
							"trackingInfo": {
								"shipDateTime": zDateFormat( arguments.date ),
								"carrierName": {
									"carrier": arguments.carrier,
									"otherCarrier": nullValue()
								},
								"methodCode": arguments.methodCode,
								"trackingNumber": arguments.trackingNumber
							}
						} ]
					}
				});
			}
		}
		if ( !lines.len() ) {
			return {
				success= false
			,	error= "Order !ready to ship"
			,	order= order
			};
		}
		arguments.json = {
			"orderShipment": {
				"orderLines": {
					"orderLine": lines
				}
			}
		};
		return this.apiRequest( api= "POST /orders/{id}/shipping", argumentCollection= arguments );
	}

	struct function acknowledgeOrder( required string id, required string carrier, required string trackingNumber, string methodCode= "Standard", string date= now() ) {
		return this.apiRequest( api= "POST /orders/{id}/acknowledge", argumentCollection= arguments );
	}

	struct function cancelFullOrder( required string id, required string reason ) {
		var order= this.getOrder( arguments.id );
		var lines= [];
		for ( l in order.data.order.orderLines.orderLine ) {
			arrayAppend( lines, {
				"lineNumber": l.lineNumber,
				"orderLineStatuses": {
					"orderLineStatus": [ {
						"status": "Cancelled",
						"cancellationReason": arguments.reason,
						"statusQuantity": l.orderLineQuantity,
					} ]
				}
			});
		}
		arguments.body = {
			"orderShipment": {
				"orderLines": {
					"orderLine": lines
				}
			}
		};
		return this.apiRequest( api= "POST /orders/{id}/cancel", argumentCollection= arguments );
	}

	// ---------------------------------------------------------------------------- 
	// HELPER 
	// ---------------------------------------------------------------------------- 

	string function structToQueryString( required struct stInput, string sUrl= "", boolean bEncode= true ) {
		var sOutput= "";
		var sItem= "";
		var sValue= "";
		var amp= ( find( "?", arguments.sUrl ) ? "&" : "?" );
		for ( sItem in stInput ) {
			sValue= stInput[ sItem ];
			if ( !isNull( sValue ) && len( sValue ) ) {
				if ( bEncode ) {
					sOutput &= amp & sItem & "=" & urlEncodedFormat( sValue );
				} else {
					sOutput &= amp & sItem & "=" & sValue;
				}
				amp= "&";
			}
		}
		return sOutput;
	}

	string function structToQueryString2( required struct stInput, boolean bEncode= true ) {
		var sOutput= "";
		var sItem= "";
		var sValue= "";
		var amp= "";
		for ( sItem in stInput ) {
			sValue= stInput[ sItem ];
			if ( !isNull( sValue ) && len( sValue ) ) {
				sOutput &= amp & sItem & "=" & sValue;
				amp= "&";
			}
		}
		return sOutput;
	}

	string function zDateFormat( required string date ) {
		if ( !len( arguments.date ) ) {
			return "";
		}
		arguments.date = dateAdd( "s", this.offSet, arguments.date );
		return dateFormat( arguments.date, "yyyy-mm-dd" ) & "T" & timeFormat( arguments.date, "HH:mm:ss") & "Z";
	}

	date function epochParse( required string date ) {
		return dateAdd( "l", arguments.date, dateConvert( "utc2Local", "January 1 1970 00:00" ) );
	}

}
